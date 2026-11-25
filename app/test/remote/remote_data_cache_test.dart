import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/remote/cache/remote_data_cache.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _session(String id, {int updatedAt = 1000}) => SessionSummary.fromJson({
  'sessionId': id,
  'updatedAt': updatedAt,
  'running': false,
  'blank': false,
  'agentAvailable': true,
  'cwd': '/work',
  'projections': {
    'asOfSeq': 1,
    'values': {'title': 'title $id'},
  },
});

SessionLogEvent _event(int seq) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1700000000000 + seq, 'type': 'session/title', 'data': {'title': 'r$seq'}});

void main() {
  late Directory root;

  RemoteDataCache build({bool enabled = true, int maxEvents = 400, int maxTranscriptBytes = 512 * 1024}) =>
      RemoteDataCache(
        enabled: enabled,
        root: () async => root,
        maxEvents: maxEvents,
        maxTranscriptBytes: maxTranscriptBytes,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('remote-cache-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the session list round-trips with its projections', () async {
    final cache = build();
    await cache.writeSessions('relay:a', [_session('s1', updatedAt: 7), _session('s2', updatedAt: 9)]);
    final rows = await cache.readSessions('relay:a');
    expect(rows!.map((s) => s.sessionId), ['s1', 's2']);
    expect(rows.first.title, 'title s1');
    expect(rows.last.updatedAt.millisecondsSinceEpoch, 9);
  });

  test('one host never reads another host cache', () async {
    final cache = build();
    await cache.writeSessions('relay:a', [_session('s1')]);
    expect(await cache.readSessions('relay:b'), isNull);
  });

  test('a transcript round-trips with its resume cursor and times', () async {
    final cache = build();
    await cache.writeTranscript('relay:a', 's1', [for (var seq = 1; seq <= 5; seq++) _event(seq)]);
    final tail = await cache.readTranscript('relay:a', 's1');
    expect(tail!.cursor, 5);
    expect(tail.events.map((e) => e.seq), [1, 2, 3, 4, 5]);
    expect(tail.events.first.time.millisecondsSinceEpoch, 1700000000001);
  });

  test('a transcript keeps only its newest events', () async {
    final cache = build(maxEvents: 3);
    await cache.writeTranscript('relay:a', 's1', [for (var seq = 1; seq <= 5; seq++) _event(seq)]);
    final tail = await cache.readTranscript('relay:a', 's1');
    expect(tail!.events.map((e) => e.seq), [3, 4, 5]);
    expect(tail.cursor, 5);
  });

  test('a transcript also stays inside its byte budget', () async {
    final cache = build(maxTranscriptBytes: 200);
    await cache.writeTranscript('relay:a', 's1', [for (var seq = 1; seq <= 20; seq++) _event(seq)]);
    final tail = await cache.readTranscript('relay:a', 's1');
    expect(tail!.cursor, 20);
    expect(tail.events.length, lessThan(20));
    expect(tail.events.last.seq, 20);
  });

  test('a fresh instance resumes from the index before reading any transcript', () async {
    await build().writeTranscript('relay:a', 's1', [for (var seq = 1; seq <= 4; seq++) _event(seq)]);
    final fresh = build();
    // A follow asks this synchronously, so it must be there without a read.
    expect(fresh.cachedCursor('relay:a', 's1'), isNull);
    await fresh.hydrate();
    expect(fresh.cachedCursor('relay:a', 's1'), 4);
    expect(fresh.cachedCursor('relay:b', 's1'), isNull);
    await fresh.clear();
    expect(fresh.cachedCursor('relay:a', 's1'), isNull);
  });

  test('attachment bytes round-trip and clear() empties the cache', () async {
    final cache = build();
    await cache.writeAttachment('relay:a', 's1/img1', Uint8List.fromList([1, 2, 3, 250]));
    expect(await cache.readAttachment('relay:a', 's1/img1'), [1, 2, 3, 250]);
    await cache.clear();
    expect(await cache.readAttachment('relay:a', 's1/img1'), isNull);
    expect(await cache.readSessions('relay:a'), isNull);
  });

  test('a disabled cache writes and reads nothing', () async {
    final cache = build(enabled: false);
    await cache.writeSessions('relay:a', [_session('s1')]);
    await cache.writeTranscript('relay:a', 's1', [_event(1)]);
    await cache.writeAttachment('relay:a', 's1/img1', Uint8List.fromList([1]));
    expect(await cache.readSessions('relay:a'), isNull);
    expect(await cache.readTranscript('relay:a', 's1'), isNull);
    expect(await cache.readAttachment('relay:a', 's1/img1'), isNull);
    expect(await root.list().toList(), isEmpty);
  });
}
