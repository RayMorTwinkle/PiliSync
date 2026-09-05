import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WtSignalingClient host;
  late WtSignalingClient member;

  setUpAll(() async {
    host = WtSignalingClient();
    member = WtSignalingClient();
  });

  tearDownAll(() async {
    await host.dispose();
    await member.dispose();
  });

  test('end-to-end: host creates room, member joins, navigate flows', () async {
    final hostEvents = <WtEvent>[];
    final memberEvents = <WtEvent>[];
    final hostSub = host.events.listen(hostEvents.add);
    final memberSub = member.events.listen(memberEvents.add);

    await host.connect(
      serverBase: '127.0.0.1:9901',
      room: 'e2e1',
      user: 'h1',
      pass: '',
      isHost: true,
    );
    await member.connect(serverBase: '127.0.0.1:9901', room: 'e2e1', user: 'm1', pass: '');

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

    member.updateMember(true);
    final mu = await waitForEvent<WtMemberUpdateEvent>(
      hostEvents,
      const Duration(seconds: 3),
    );
    expect(mu.isLoading, isTrue);
    expect(mu.waitForLoadding, isTrue);

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
