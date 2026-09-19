import 'package:PiliPlus/services/watch_together/watch_together_service.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'wt_member_coordinator_test.dart' show FakePlayer;

class RecordingSignaling extends WtSignalingClient {
  final loadingReports = <bool>[];
  @override
  bool updateMember(bool isLoading, {WtTarget? target}) {
    loadingReports.add(isLoading);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('authoritative ack releases barrier after loading member leaves', () async {
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    service.role.value = WtRole.host;
    service.inRoom.value = true;
    service.handleEventForTesting(const WtMemberUpdateEvent('member', true, true, 2));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isFalse);
    service.handleEventForTesting(const WtUpdateAckEvent(
      WtRoomSnapshot(name: 'test', isHost: true, isProtected: false,
        memberCount: 1, waitForLoadding: false,
        playback: WtPlaybackState(paused: false, currentTime: 308)), 100,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isTrue);
    expect(player.commands, ['pause', 'play']);
    service.handleEventForTesting(WtUpdateAckEvent(service.room.value!, 101));
    await Future<void>.delayed(Duration.zero);
    expect(player.commands, ['pause', 'play']);
  });

  test('barrier release snapshot respects explicit host pause', () async {
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    service.role.value = WtRole.host;
    service.inRoom.value = true;
    service.handleEventForTesting(const WtMemberUpdateEvent('member', true, true, 2));
    await Future<void>.delayed(Duration.zero);
    service.hostIntent.onPlaybackRequest(false);
    service.handleEventForTesting(const WtUpdateAckEvent(
      WtRoomSnapshot(name: 'test', isHost: true, isProtected: false,
        memberCount: 1, waitForLoadding: false,
        playback: WtPlaybackState(paused: true, currentTime: 308)), 100,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isFalse);
    expect(player.commands, ['pause']);
  });

  test('service resumes member after paused seek and does not freeze at target', () async {
    final player = FakePlayer();
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player,
      client: client,
      clock: () => now,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    void room(bool paused) {
      service.room.value = WtRoomSnapshot(
        name: 'test', isHost: false, isProtected: false, memberCount: 2,
        waitForLoadding: false,
        playback: WtPlaybackState(
          paused: paused, currentTime: 10, duration: 120,
          lastUpdateClientTime: now,
        ),
      );
    }
    room(true);
    await service.tickForTesting();
    expect(player.positionMs, 10000);
    for (var i = 0; i < 3; i++) {
      now += 1;
      room(false);
      await service.tickForTesting();
      player.advance(0.25);
    }
    expect(player.positionMs, greaterThan(10000), reason:
      'commands=${player.commands}; loading=${client.loadingReports}; '
      'logs=${service.debugLog.map((entry) => entry.msg).toList()}');
    expect(player.commands, contains('play'));
    expect(client.loadingReports, isNot(contains(true)));
    now += 1;
    room(true);
    await service.tickForTesting();
    expect(player.isPlaying, isFalse);
    expect(player.commands.last, 'pause');
  }, timeout: const Timeout(Duration(seconds: 5)));
}
