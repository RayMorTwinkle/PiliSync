import 'dart:async';

import 'package:PiliPlus/services/watch_together/wt_member_coordinator.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePlayer implements WtPlayerAdapter, WtPlaybackCommandSource {
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
  final _bufferingCtl =
      StreamController<bool>.broadcast(sync: true);
  final _playbackReqCtl =
      StreamController<({bool playing, bool isInterrupt})>.broadcast(
        sync: true,
      );

  /// Simulate a buffering edge: flips the flag AND emits the event.
  void setBuffering(bool v) {
    isBuffering = v;
    _bufferingCtl.add(v);
  }

  /// Simulate a user/system playback command (not a sync-issued one).
  void emitPlaybackRequest({required bool playing, bool isInterrupt = false}) {
    _playbackReqCtl.add((playing: playing, isInterrupt: isInterrupt));
  }

  @override
  StreamSubscription<void> onStatusChanged(void Function(bool) cb) =>
      const Stream<void>.empty().listen(null);
  @override
  StreamSubscription<bool> onBufferingChanged(void Function(bool) cb) =>
      _bufferingCtl.stream.listen(cb);
  @override
  StreamSubscription<({bool playing, bool isInterrupt})> onPlaybackRequest(
    void Function(bool playing, bool isInterrupt) cb,
  ) => _playbackReqCtl.stream.listen((r) => cb(r.playing, r.isInterrupt));

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

  test('buffering seek exemption is capped — wedged player still realigns', () async {
    // F12-i: a member whose isBuffering never clears must still get an
    // occasional realign seek — the report cap (20s) frees the room
    // barrier, but without a matching cap on the seek exemption the
    // member would drift forever.
    final member = WtMemberCoordinator();
    final player = FakePlayer()
      ..isPlaying = true
      ..isBuffering = true
      ..positionMs = 0;
    final logs = <String>[];
    Future<void> tick(double now) => member.tick(
      room: WtPlaybackState(
        paused: false,
        currentTime: 50,
        duration: 120,
        lastUpdateClientTime: now,
      ),
      waitForLoading: false,
      now: now,
      player: player,
      reportLoading: (_) {},
      log: logs.add,
    );

    await tick(100);
    expect(
      player.commands.where((c) => c.startsWith('seek')),
      isEmpty,
      reason: 'buffering member exempt from seeks within the cap',
    );

    // Past the 20s exemption cap: one realign seek is allowed.
    await tick(125);
    expect(
      player.commands.where((c) => c.startsWith('seek')),
      isNotEmpty,
      reason: 'commands=${player.commands}',
    );

    // The realign seek restarted the exemption run — suppress again.
    player.positionMs = 0;
    await tick(127);
    expect(
      player.commands.where((c) => c.startsWith('seek')),
      hasLength(1),
      reason: 'commands=${player.commands}',
    );
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('allowPlay=false suppresses auto-play, never auto-pause', () async {
    // F12-m member side: after an external pause (manual or audio
    // interrupt) the member must not be yanked back to play instantly.
    final member = WtMemberCoordinator();
    final player = FakePlayer()
      ..isPlaying = false
      ..positionMs = 10000;
    Future<void> tick(double now, {bool allowPlay = true}) => member.tick(
      room: WtPlaybackState(
        paused: false,
        currentTime: 10,
        duration: 120,
        lastUpdateClientTime: now,
      ),
      waitForLoading: false,
      now: now,
      player: player,
      reportLoading: (_) {},
      log: (_) {},
      allowPlay: allowPlay,
    );

    await tick(100, allowPlay: false);
    expect(player.commands, isNot(contains('play')));

    // Cooldown over → auto-play resumes.
    await tick(101);
    expect(player.commands, contains('play'));
  }, timeout: const Timeout(Duration(seconds: 5)));
}
