import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';

/// On-disk copy of one Host's display data: the session list, each transcript
/// tail and cached attachment bytes.
///
/// Everything here is a *display* cache: it makes the first frame warm and lets
/// a follow resume from the last cached sequence instead of replacing the log.
/// The Host always stays authoritative — a read miss or a stale entry only costs
/// one round trip, never correctness. Nothing secret (credentials, headers) is
/// written; keys are digests so ids never appear on disk.
class RemoteDataCache {
  /// Cache key for one Host selection; the name shown in the UI is not part
  /// of it, so renaming a Host keeps its cache.
  static String hostKey(HostRef host) => '${host.kind.name}:${host.id}';
  RemoteDataCache({
    required this.enabled,
    Future<Directory> Function()? root,
    this.maxSessions = 200,
    this.maxEvents = 400,
    this.maxTranscriptBytes = 512 * 1024,
    this.maxAttachmentBytes = 8 * 1024 * 1024,
  }) : _root = root ?? _supportRoot;

  /// The "本地保存远程数据" preference. Disabled means every method is a no-op.
  final bool enabled;
  final Future<Directory> Function() _root;

  /// Rows kept in the cached list (most recent first).
  final int maxSessions;

  /// Events kept in a cached transcript tail.
  final int maxEvents;
  final int maxTranscriptBytes;
  final int maxAttachmentBytes;

  static Future<Directory> _supportRoot() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/remote-cache');

  static String _digest(String value) => sha256.convert(utf8.encode(value)).toString().substring(0, 32);

  /// Where a follow can resume one transcript, keyed by digests only.
  final Map<String, int> _cursors = {};
  bool _hydrated = false;

  static String _cursorKey(String hostKey, String sessionId) =>
      '${_digest(hostKey)}/${_digest(sessionId)}';

  /// The last cached sequence of one transcript, without touching the disk.
  ///
  /// A follow asks this before it opens: a hit resumes from there, and a miss
  /// (a cold index, or a transcript never cached) costs exactly one full read.
  int? cachedCursor(String hostKey, String sessionId) {
    if (!enabled) return null;
    return _cursors[_cursorKey(hostKey, sessionId)];
  }

  /// Loads the cursor index once. It is a few hundred bytes, so a follow that
  /// opens later in the run resumes synchronously instead of waiting for it.
  Future<void> hydrate() async {
    if (!enabled || _hydrated) return;
    _hydrated = true;
    final base = await _base();
    if (base == null) return;
    try {
      final file = File('${base.path}/index.json');
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is int) _cursors[key] = value;
      }
    } on Object {
      // A missing index only costs one full follow.
    }
  }

  Future<Directory?> _base() async {
    if (!enabled) return null;
    try {
      return await _root();
    } on Object {
      return null;
    }
  }

  Future<void> _writeIndex() async {
    final base = await _base();
    if (base == null) return;
    try {
      await base.create(recursive: true);
      await _replace('${base.path}/index.json', utf8.encode(jsonEncode(_cursors)));
    } on Object {
      // Best effort: the transcript files still carry their own sequences.
    }
  }

  Future<Directory?> _dir(String hostKey, {bool create = true}) async {
    final base = await _base();
    if (base == null) return null;
    try {
      final dir = Directory('${base.path}/hosts/${_digest(hostKey)}');
      if (!create) return dir;
      return await dir.create(recursive: true);
    } on Object {
      // A cache that cannot be written is simply absent.
      return null;
    }
  }

  /// Replaces [path] in one rename, so a kill mid-write cannot leave a
  /// truncated cache behind.
  Future<void> _replace(String path, List<int> bytes) async {
    final temp = File('$path.tmp');
    await temp.writeAsBytes(bytes, flush: false);
    await temp.rename(path);
  }

  Future<List<SessionSummary>?> readSessions(String hostKey) async {
    final dir = await _dir(hostKey, create: false);
    if (dir == null) return null;
    try {
      final file = File('${dir.path}/sessions.json');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      final rows = decoded is Map ? decoded['sessions'] : null;
      if (rows is! List) return null;
      return [for (final row in rows) SessionSummary.fromJson(row)];
    } on Object {
      return null;
    }
  }

  Future<void> writeSessions(String hostKey, List<SessionSummary> sessions) async {
    final dir = await _dir(hostKey);
    if (dir == null) return;
    try {
      final rows = sessions.take(maxSessions).map((session) => session.raw).toList(growable: false);
      await _replace('${dir.path}/sessions.json', utf8.encode(jsonEncode({'version': 1, 'sessions': rows})));
    } on Object {
      // Best effort.
    }
  }

  /// The cached tail of one transcript, oldest first, with the sequence a
  /// follow can resume from.
  Future<({List<SessionLogEvent> events, int cursor})?> readTranscript(String hostKey, String sessionId) async {
    final dir = await _dir(hostKey, create: false);
    if (dir == null) return null;
    try {
      final file = File('${dir.path}/${_digest(sessionId)}.jsonl');
      if (!await file.exists()) return null;
      final events = <SessionLogEvent>[];
      for (final line in const LineSplitter().convert(await file.readAsString())) {
        if (line.isEmpty) continue;
        final event = SessionLogEvent.fromJson(jsonDecode(line));
        if (event.seq < 0) continue;
        events.add(event);
      }
      if (events.isEmpty) return null;
      _cursors[_cursorKey(hostKey, sessionId)] = events.last.seq;
      return (events: events, cursor: events.last.seq);
    } on Object {
      return null;
    }
  }

  Future<void> writeTranscript(String hostKey, String sessionId, Iterable<SessionLogEvent> events) async {
    if (!enabled) return;
    final tail = events.toList(growable: false);
    if (tail.isEmpty) return;
    // Recorded before the write so a follow opening meanwhile already resumes.
    _cursors[_cursorKey(hostKey, sessionId)] = tail.last.seq;
    final dir = await _dir(hostKey);
    if (dir == null) return;
    try {
      final lines = [
        for (final event in tail.length > maxEvents ? tail.sublist(tail.length - maxEvents) : tail)
          jsonEncode({
            'seq': event.seq,
            'time': event.time.millisecondsSinceEpoch,
            'type': event.type,
            'data': event.data,
          }),
      ];
      // Keep the newest lines inside the byte budget.
      var bytes = lines.fold<int>(0, (sum, line) => sum + utf8.encode(line).length + 1);
      var first = 0;
      while (bytes > maxTranscriptBytes && first < lines.length - 1) {
        bytes -= utf8.encode(lines[first]).length + 1;
        first++;
      }
      await _replace('${dir.path}/${_digest(sessionId)}.jsonl', utf8.encode('${lines.sublist(first).join('\n')}\n'));
      await _writeIndex();
    } on Object {
      // Best effort.
    }
  }

  Future<Uint8List?> readAttachment(String hostKey, String attachmentId) async {
    final dir = await _dir(hostKey, create: false);
    if (dir == null) return null;
    try {
      final file = File('${dir.path}/${_digest(attachmentId)}.bin');
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on Object {
      return null;
    }
  }

  Future<void> writeAttachment(String hostKey, String attachmentId, Uint8List bytes) async {
    if (bytes.length > maxAttachmentBytes) return;
    final dir = await _dir(hostKey);
    if (dir == null) return;
    try {
      await _replace('${dir.path}/${_digest(attachmentId)}.bin', bytes);
    } on Object {
      // Best effort.
    }
  }

  /// Drops every cached Host (turning the preference off).
  Future<void> clear() async {
    _cursors.clear();
    _hydrated = false;
    try {
      await (await _root()).delete(recursive: true);
    } on Object {
      // Nothing cached.
    }
  }
}

/// The cache bound to the "本地保存远程数据" preference, for remote Hosts only:
/// this phone's own engine reads fast enough that a copy only adds staleness.
/// Turning the preference off sweeps what is already on disk.
final remoteDataCacheProvider = Provider<RemoteDataCache>((ref) {
  final enabled = ref.watch(settingsProvider.select((settings) => settings.cacheRemoteData));
  final host = ref.watch(activeHostProvider);
  if (!enabled) unawaited(RemoteDataCache(enabled: false).clear());
  final cache = RemoteDataCache(enabled: enabled && !host.isLocal);
  // One small read now lets the first follow resume from the cached sequence
  // instead of asking the Host for the whole log again.
  unawaited(cache.hydrate());
  return cache;
});
