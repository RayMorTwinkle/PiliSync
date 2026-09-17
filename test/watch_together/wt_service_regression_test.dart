import 'package:PiliPlus/services/watch_together/watch_together_service.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'wt_member_coordinator_test.dart' show FakePlayer;

class RecordingSignaling extends WtSignalingClient {
  final loadingReports = <bool>[];
  @override
  void updateMember(bool isLoading) => loadingReports.add(isLoading);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        name: 'test', hostId: 'host', isProtected: false, memberCount: 2,
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
