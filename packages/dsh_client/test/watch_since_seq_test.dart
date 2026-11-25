import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';
import 'support/history_fill_harness.dart' show historyFrame, historySnapshot;

/// A watch opened with [WatchOptions.sinceSeq] merges into what the caller
/// already has instead of replacing it: that is what lets the app resume a
/// transcript it read back from disk.
class _Opened {
  _Opened(this.host, this.client, this.sub, this.snapshots, this.requests, this.errors);

  final FakeDsh host;
  final DshClient client;
  final StreamSubscription<DshEvent> sub;
  final List<SessionSnapshotEvent> snapshots;
  final List<Map<String, Object?>> requests;
  final List<Object> errors;

  Future<void> close() async {
    await sub.cancel();
    await client.close();
    await host.close();
  }
}

SessionLogEvent _event(int seq) => SessionLogEvent.fromJson(historyFrame(seq)['event']);

Future<_Opened> _open({
  required int cursor,
  required List<Map<String, Object?>> records,
  int? sinceSeq,
  Map<int, List<Map<String, Object?>>> pages = const {},
}) async {
  final host = await FakeDsh.start();
  final connection = DshConnection(host.baseUri);
  await connection.login(FakeDsh.token);
  final client = DshClient(connection);
  final requests = <Map<String, Object?>>[];
  final snapshots = <SessionSnapshotEvent>[];
  final errors = <Object>[];
  final first = Completer<SessionSnapshotEvent>();
  host.handlers['session/page'] = (args) {
    final request = Map<String, Object?>.from(args['request']! as Map);
    requests.add(request);
    return {
      'ok': true,
      'value': {'records': pages[request['beforeSeq']! as int] ?? const <Map<String, Object?>>[], 'hasMore': false},
    };
  };
  host.onOpen = (socket, id, endpoint, payload) {
    if (endpoint != 'session/follow') return;
    socket.item(id, historySnapshot(cursor, records));
  };
  final sub = client
      .watch(
        's',
        options: WatchOptions(sinceSeq: sinceSeq, includeSyncEvents: false, includeHostEvents: false),
      )
      .listen(
        (event) {
          if (event is! SessionSnapshotEvent) return;
          snapshots.add(event);
          if (!first.isCompleted) first.complete(event);
        },
        onError: errors.add,
      );
  try {
    await Future.any<Object?>([
      first.future,
      Future<SessionSnapshotEvent>.delayed(
        const Duration(seconds: 20),
        () => throw TimeoutException('no snapshot'),
      ),
    ]);
  } on Object {
    await sub.cancel();
    await client.close();
    await host.close();
    rethrow;
  }
  return _Opened(host, client, sub, snapshots, requests, errors);
}

void main() {
  test('a contiguous snapshot resyncs from the cached cursor without a page', () async {
    final opened = await _open(cursor: 8, records: [historyFrame(7), historyFrame(8)], sinceSeq: 6);
    try {
      final snapshot = opened.snapshots.single;
      expect(snapshot.isResync, isTrue);
      expect(snapshot.cursor, 8);
      expect(snapshot.events.map((e) => e.seq), [7, 8]);
      expect(opened.requests, isEmpty);
    } finally {
      await opened.close();
    }
    expect(opened.errors, isEmpty);
  });

  test('the gap between the cached cursor and the snapshot is filled, not replaced', () async {
    final opened = await _open(
      cursor: 10,
      records: [historyFrame(10)],
      sinceSeq: 6,
      pages: {
        10: [historyFrame(7), historyFrame(8), historyFrame(9)],
      },
    );
    try {
      final snapshot = opened.snapshots.single;
      expect(snapshot.isResync, isTrue);
      expect(snapshot.events.map((e) => e.seq), [7, 8, 9, 10]);
      expect(opened.requests.single['beforeSeq'], 10);
      expect(opened.requests.single['throughSeq'], 10);
    } finally {
      await opened.close();
    }
    expect(opened.errors, isEmpty);
  });

  test('a cached cursor older than history retention resyncs without the partial fill', () async {
    final opened = await _open(
      cursor: 10,
      records: [historyFrame(10)],
      sinceSeq: 6,
      pages: {
        10: [historyFrame(8), historyFrame(9)],
      },
    );
    try {
      final snapshot = opened.snapshots.single;
      expect(snapshot.isResync, isFalse);
      expect(snapshot.events.map((e) => e.seq), [10]);
      expect(opened.requests, hasLength(1));
    } finally {
      await opened.close();
    }
    expect(opened.errors, isEmpty);
  });

  test('a replaced Host log drops the cached cursor instead of merging', () async {
    final opened = await _open(
      cursor: 3,
      records: [for (var seq = 1; seq <= 3; seq++) historyFrame(seq)],
      sinceSeq: 9,
    );
    try {
      final snapshot = opened.snapshots.single;
      expect(snapshot.isResync, isFalse);
      expect(snapshot.events.map((e) => e.seq), [1, 2, 3]);
      expect(opened.requests, isEmpty);
    } finally {
      await opened.close();
    }
    expect(opened.errors, isEmpty);
  });

  test('a seeded transcript keeps its cached tail across the resync snapshot', () async {
    final opened = await _open(cursor: 8, records: [historyFrame(7), historyFrame(8)], sinceSeq: 6);
    try {
      final transcript = ChatTranscript()..seedTail([for (var seq = 1; seq <= 6; seq++) _event(seq)]);
      transcript.apply(opened.snapshots.single);
      expect(transcript.events.map((e) => e.seq), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(transcript.cursor, 8);
    } finally {
      await opened.close();
    }
  });
}
