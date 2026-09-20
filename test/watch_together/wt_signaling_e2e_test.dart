import 'dart:io';

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Local e2e: requires a signaling server on 127.0.0.1:9901
/// (`cd signaling && go run .`). Skips cleanly when it is not running.
Future<bool> signalingUp() async {
  try {
    final c = await Socket.connect(
      '127.0.0.1',
      9901,
      timeout: const Duration(milliseconds: 500),
    );
    await c.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WtSignalingClient host;
  late WtSignalingClient member;

  setUpAll(() {
    host = WtSignalingClient();
    member = WtSignalingClient();
  });

  tearDownAll(() async {
    await host.dispose();
    await member.dispose();
  });

  test('end-to-end: host creates room, member joins, navigate flows', () async {
    if (!await signalingUp()) {
      markTestSkipped('signaling server not running on 127.0.0.1:9901');
      return;
    }
    // Unique room per run: a lingering room from a previous run keeps
    // HostId bound to a dead tempUser after host-handover, so reusing the
    // same name makes the new host fail with other_host_syncing.
    final room = 'e2e1-${DateTime.now().microsecondsSinceEpoch}';
    final hostEvents = <WtEvent>[];
    final memberEvents = <WtEvent>[];
    final hostSub = host.events.listen(hostEvents.add);
    final memberSub = member.events.listen(memberEvents.add);

    await host.connect(
      serverBase: '127.0.0.1:9901',
      room: room,
      user: 'h1',
      pass: '',
    );
    host.join();
    host.updatePlayback(
      WtPlaybackState(lastUpdateClientTime: host.timeSync.now()),
    );
    await member.connect(serverBase: '127.0.0.1:9901', room: room, user: 'm1', pass: '');
    member.join();

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      hostEvents.any((e) => e is WtUpdateAckEvent),
      isTrue,
      reason: 'host should receive update_ack (creates room via update)',
    );
    expect(memberEvents.any((e) => e is WtJoinedEvent), isTrue);

    expect(host.timeSync.hasValidSample, isTrue,
        reason: 'time sync should have HTTP sample');

    host.updatePlayback(
      const WtPlaybackState(
        currentTime: 42,
        paused: false,
        playbackRate: 1,
        lastUpdateClientTime: 0,
      ),
    );

    final roomMsg = await waitForEvent<WtRoomUpdateEvent>(
      memberEvents,
      const Duration(seconds: 3),
    );
    expect(roomMsg.room.playback.currentTime, 42);
    expect(roomMsg.room.playback.paused, isFalse);

    host.navigate(const WtTarget(type: 'video', bvid: 'BV1test', cid: 99));
    final nav = await waitForEvent<WtNavigateEvent>(
      memberEvents,
      const Duration(seconds: 3),
    );
    expect(nav.target.bvid, 'BV1test');
    expect(nav.target.cid, 99);

    member.updateMember(
      true,
      target: const WtTarget(type: 'video', bvid: 'BV1test', cid: 99),
    );
    final mu = await waitForEvent<WtMemberUpdateEvent>(
      hostEvents,
      const Duration(seconds: 3),
    );
    expect(mu.isLoading, isTrue);
    expect(mu.waitForLoadding, isTrue,
        reason: 'hostEvents=${hostEvents.map((e) => e.toString()).toList()}');

    await hostSub.cancel();
    await memberSub.cancel();
    await host.disconnect();
    await member.disconnect();
  }, timeout: const Timeout(Duration(seconds: 15)));
}

Future<T> waitForEvent<T>(List<WtEvent> events, Duration timeout) async {
  final startCount = events.length;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final e in events.skip(startCount)) {
      if (e is T) return e as T;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timeout waiting for $T');
}
