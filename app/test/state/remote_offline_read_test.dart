import 'dart:io';

import 'package:dsh_app/remote/cache/remote_data_cache.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'read_list_refresh_test.dart'
    show
        FixedHost,
        SwitchConnection,
        SwitchIdentity,
        SwitchWorkspacePrefs,
        SwitchWorkspaces,
        switchConnectionProvider,
        switchIdentityProvider;

SessionSummary _session(String id, {String? title, int updatedAt = 1000, bool blank = false, String origin = 'user'}) =>
    SessionSummary.fromJson({
      'sessionId': id,
      'updatedAt': updatedAt,
      'running': false,
      'blank': blank,
      'origin': origin,
      'agentAvailable': true,
      'cwd': '/work',
      'projections': {
        'asOfSeq': 1,
        'values': {'title': ?title},
      },
    });

SessionLogEvent _event(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1793000000000 + seq, 'type': type, 'data': data});

SessionLogEvent _prompt(int seq, String text) => _event(seq, 'user/message', {
  'id': 'm$seq',
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': 'user', 'rpcId': 'rpc-$seq'},
});

/// A container with no Host connection at all: the cold start this phone sees
/// with the network gone.
ProviderContainer _offline(RemoteDataCache cache) => ProviderContainer(
  overrides: <Override>[
    activeHostProvider.overrideWith(FixedHost.new),
    switchConnectionProvider.overrideWith(() => SwitchConnection(null)),
    activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
    switchIdentityProvider.overrideWith(() => SwitchIdentity(null)),
    readListIdentityProvider.overrideWith((ref) => ref.watch(switchIdentityProvider)),
    localSafeModeProvider.overrideWithValue(false),
    workspacesProvider.overrideWith(() => SwitchWorkspaces()),
    workspacePrefsProvider.overrideWith(() => SwitchWorkspacePrefs()),
    dsBotOwnedSessionsProvider.overrideWithValue(const {}),
    remoteDataCacheProvider.overrideWithValue(cache),
  ],
);

/// Waits for the disk reads behind a cold start.
Future<void> _settle(ProviderContainer c) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await c.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late Directory root;
  late RemoteDataCache cache;
  late String hostKey;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('offline-read-test');
    cache = RemoteDataCache(enabled: true, root: () async => root);
    hostKey = RemoteDataCache.hostKey(HostRef.local);
  });

  tearDown(() async {
    // A disposed conversation writes its tail once more before it lets go.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on Object {
      // Windows keeps the file until that late write returns; the temp root
      // is disposable either way.
    }
  });

  test('a drawer with no connection lists what the phone kept, read-only and flat', () async {
    await cache.writeSessions(hostKey, [
      _session('old', title: 'Oldest', updatedAt: 1000),
      _session('new', title: 'Newest', updatedAt: 3000),
      _session('blank', updatedAt: 4000, blank: true),
      _session('child', updatedAt: 5000, origin: 'subagent'),
    ]);
    final c = _offline(cache);
    addTearDown(c.dispose);
    c.listen(sessionsProvider, (_, _) {});
    c.listen(cachedSessionRowsProvider, (_, _) {});
    await _settle(c);

    final scope = c.read(drawerScopeProvider)!;
    expect(scope.sessions.map((row) => row.sessionId), ['new', 'old']);
    expect(scope.readOnly, isTrue);
    expect(scope.status, ReadListStatus.offline);
    expect(scope.bots, isEmpty);
    expect(scope.scoped, isFalse);
  });

  test('no cached list means no drawer scope, never a made-up one', () async {
    final c = _offline(cache);
    addTearDown(c.dispose);
    c.listen(sessionsProvider, (_, _) {});
    c.listen(cachedSessionRowsProvider, (_, _) {});
    await _settle(c);
    expect(c.read(drawerScopeProvider), isNull);
  });

  test('a conversation opened while the Host is away shows the kept tail', () async {
    await cache.writeSessions(hostKey, [_session('s1', title: 'Kept title', updatedAt: 2000)]);
    await cache.writeTranscript(hostKey, 's1', [
      _event(1, 'session/title', {'title': 'log title'}),
      _prompt(2, 'hello'),
    ]);
    final c = _offline(cache);
    addTearDown(c.dispose);
    c.listen(chatProvider('s1'), (_, _) {});
    await _settle(c);

    final state = c.read(chatProvider('s1'));
    expect(state.offline, isTrue);
    expect(state.items, isNotEmpty);
    expect(state.controlReady, isFalse);
    // The list's projection is newer than whatever the tail still carries.
    expect(state.title, 'Kept title');
    expect(state.hasMoreHistory, isFalse);
  });

  test('a kept tail without a kept list still titles from the log', () async {
    await cache.writeTranscript(hostKey, 's2', [
      _event(1, 'session/title', {'title': 'log only'}),
    ]);
    final c = _offline(cache);
    addTearDown(c.dispose);
    c.listen(chatProvider('s2'), (_, _) {});
    await _settle(c);

    final state = c.read(chatProvider('s2'));
    expect(state.offline, isTrue);
    expect(state.title, 'log only');
  });

  test('nothing kept is still an empty offline conversation, not a spinner', () async {
    final c = _offline(cache);
    addTearDown(c.dispose);
    c.listen(chatProvider('gone'), (_, _) {});
    await _settle(c);

    final state = c.read(chatProvider('gone'));
    expect(state.offline, isTrue);
    expect(state.items, isEmpty);
    expect(state.loading, isFalse);
  });
}
