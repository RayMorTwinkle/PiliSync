import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/watch_together/wt_member_coordinator.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_port.dart';

class Player implements WtPlayerAdapter {
  @override
  Object identity = Object();
  @override
  bool hasPlayer = true, isPlaying = true, isBuffering = false, isLive = false;
  @override
  double positionMs = 20000, durationMs = 120000, speed = 1;
  final commands = <String>[];
  Completer<void>? seekGate, rateGate;
  bool rejectSeek = false;

  @override
  Future<void> seekToMs(double ms) async {
    commands.add('seek:${ms.round()}');
    if (rejectSeek) throw StateError('scripted player refusal');
    final gate = seekGate;
    if (gate != null) await gate.future;
    positionMs = ms;
  }

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
  Future<void> setSpeed(double value) async {
    commands.add('rate:$value');
    final gate = rateGate;
    if (gate != null) await gate.future;
    speed = value;
  }

  @override
  StreamSubscription<void> onStatusChanged(void Function(bool) cb) =>
      const Stream<void>.empty().listen(null);

  @override
  StreamSubscription<bool> onBufferingChanged(void Function(bool) cb) =>
      const Stream<bool>.empty().listen(cb);
}

class Replay {
  final member = WtMemberCoordinator();
  final player = Player();
  final reports = <bool>[];

  Future<void> tick(
    double now, {
    double host = 10,
    double rate = 1,
    bool paused = false,
    bool loose = false,
    bool clockReady = true,
    bool allowPlay = true,
  }) => member.tick(
    room: WtPlaybackState(
      currentTime: host,
      lastUpdateClientTime: now,
      duration: 120,
      paused: paused,
      playbackRate: rate,
    ),
    waitForLoading: false,
    now: now,
    player: player,
    reportLoading: reports.add,
    log: (_) {},
    canSeek: clockReady,
    allowPlay: allowPlay,
    looseSync: loose,
  );
}

typedef Observation = Future<List<Object?>> Function(Replay);

typedef RecordCheck =
    void Function(String name, List<Object?> expected, List<Object?> observed);

Future<void> replayMemberCases(RecordCheck record) async {
  Future<void> check(
    String name,
    List<Object?> expected,
    Observation run,
  ) async {
    record(name, expected, await run(Replay()));
  }

  Future<List<Object?>> afterHold(
    Replay r, {
    bool paused = false,
    bool loose = true,
    bool clockReady = true,
    bool allowPlay = true,
    double host = 10,
  }) async {
    await r.tick(100, loose: true);
    await r.tick(
      101,
      host: host,
      paused: paused,
      loose: loose,
      clockReady: clockReady,
      allowPlay: allowPlay,
    );
    return r.player.commands;
  }

  await check('hold-then-host-pauses', [
    'pause',
    'seek:10000',
  ], (r) => afterHold(r, paused: true));
  await check('hold-then-strict', [
    'pause',
    'seek:10000',
    'play',
  ], (r) => afterHold(r, loose: false));
  await check('hold-then-unsampled-clock', [
    'pause',
    'play',
  ], (r) => afterHold(r, clockReady: false));
  await check(
    'external-pause-still-honored',
    ['pause'],
    (r) => afterHold(r, clockReady: false, allowPlay: false),
  );
  await check('hold-at-release-boundary', [
    'pause',
  ], (r) => afterHold(r, host: 18));
  await check('resume-inside-release-boundary', [
    'pause',
    'play',
  ], (r) => afterHold(r, host: 18.1));
  await check('no-hold-at-entry-boundary', [], (r) async {
    await r.tick(100, host: 15, loose: true);
    return r.player.commands;
  });

  Future<List<Object?>> interrupt(Replay r, {required bool reset}) async {
    r.player.isPlaying = false;
    final gate = r.player.seekGate = Completer<void>();
    final pending = r.tick(100, rate: 1.5);
    if (reset) {
      r.member.reset();
    } else {
      r.player.identity = Object();
    }
    gate.complete();
    await pending;
    return [
      ...r.player.commands,
      r.reports.length,
      r.member.inSeekSilence(100.5),
    ];
  }

  await check('reset-during-seek', [
    'seek:10000',
    0,
    false,
  ], (r) => interrupt(r, reset: true));
  await check('player-replaced-during-seek', [
    'seek:10000',
    0,
    false,
  ], (r) => interrupt(r, reset: false));
  await check(
    'successful-command-order',
    ['seek:10000', 'rate:1.5', 'play', 1, true],
    (r) async {
      r.player.isPlaying = false;
      await r.tick(100, rate: 1.5);
      return [
        ...r.player.commands,
        r.reports.length,
        r.member.inSeekSilence(100.5),
      ];
    },
  );
  await check(
    'refused-seek-retries-next-tick',
    ['seek:10000', false, 'seek:10000', true],
    (r) async {
      r.player.rejectSeek = true;
      await r.tick(100);
      final silence = r.member.inSeekSilence(100.5);
      r.player.rejectSeek = false;
      await r.tick(101);
      return [
        r.player.commands.first,
        silence,
        ...r.player.commands.skip(1),
        r.member.inSeekSilence(101.5),
      ];
    },
  );
  await check('successful-seek-settles', ['seek:10000'], (r) async {
    await r.tick(100);
    r.player.positionMs = 20000;
    await r.tick(101);
    return r.player.commands;
  });
  await check(
    'new-player-calibrates-immediately',
    ['seek:10000', 'seek:10000'],
    (r) async {
      await r.tick(100);
      r.player.identity = Object();
      r.player.positionMs = 25000;
      await r.tick(100.25);
      return r.player.commands;
    },
  );
  await check('reset-during-rate-change', ['rate:1.5', 0], (r) async {
    r.player.isPlaying = false;
    r.player.positionMs = 10000;
    final gate = r.player.rateGate = Completer<void>();
    final pending = r.tick(100, rate: 1.5);
    r.member.reset();
    gate.complete();
    await pending;
    return [...r.player.commands, r.reports.length];
  });
  await check('refused-loose-catchup-paced', ['seek:50000', 'seek:50000'], (
    r,
  ) async {
    r.player.isBuffering = true;
    r.player.rejectSeek = true;
    await r.tick(100, host: 50, loose: true);
    await r.tick(102, host: 50, loose: true);
    await r.tick(105, host: 50, loose: true);
    return r.player.commands;
  });
}

Future<void> main() async {
  var checks = 0, passed = 0;
  await replayMemberCases((name, expected, observed) {
    final pass = jsonEncode(observed) == jsonEncode(expected);
    if (pass) passed++;
    checks++;
    stdout.writeln(
      jsonEncode({
        'case': name,
        'expected': expected,
        'observed': observed,
        'pass': pass,
      }),
    );
  });
  stdout.writeln(jsonEncode({'passed': passed, 'checks': checks}));
  if (passed != checks) exitCode = 1;
}
