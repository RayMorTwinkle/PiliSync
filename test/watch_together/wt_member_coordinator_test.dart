import 'dart:async';

import 'package:PiliPlus/services/watch_together/wt_member_coordinator.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_port.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePlayer implements WtPlayerAdapter {
  @override
  bool hasPlayer = true;
  @override
  bool isPlaying = false;
  @override
  bool isBuffering = false;
  @override
  double positionMs = 0;
  @override
  double durationMs = 120000;
  @override
  double speed = 1;
  @override
  bool isLive = false;
  @override
  Object get identity => this;
  final List<String> commands = [];
  @override
  Future<void> play() async {
    commands.add('play');
    isPlaying = true;
  }
  @override
  Future<void> pause() async {
    commands.add('pause');
    isPlaying = false;
  }
  @override
  Future<void> seekToMs(double ms) async {
    commands.add('seek:$ms');
    positionMs = ms;
  }
  @override
  Future<void> setSpeed(double value) async => speed = value;
  @override
  StreamSubscription<void> onStatusChanged(void Function(bool) cb) =>
      const Stream<void>.empty().listen(null);
  @override
  StreamSubscription<bool> onBufferingChanged(void Function(bool) cb) =>
      const Stream<bool>.empty().listen(null);

  void advance(double seconds) {
    if (isPlaying && !isBuffering) positionMs += seconds * 1000 * speed;
  }
}

void main() {
  test('seek completes while paused, then host resumes and member advances', () async {
    final member = WtMemberCoordinator();
    final player = FakePlayer();
    final logs = <String>[];
    final loading = <bool>[];
    Future<void> tick(double now, bool paused) => member.tick(
      room: WtPlaybackState(
        paused: paused,
        currentTime: 10,
        duration: 120,
        lastUpdateClientTime: now,
      ),
      waitForLoading: false,
      now: now,
      player: player,
      reportLoading: loading.add,
      log: logs.add,
    );
    await tick(100, true);
    expect(player.positionMs, 10000);
    for (var i = 0; i < 3; i++) {
      await tick(101.0 + i, false);
      player.advance(0.25);
    }
    expect(player.positionMs, greaterThan(10000),
      reason: 'commands=${player.commands}, logs=$logs, loading=$loading; '
          'clock: supplied server time, offset=0, RTT=not used');
    expect(loading.last, isFalse, reason: 'ready paused video is not buffering');
  }, timeout: const Timeout(Duration(seconds: 5)));
}
