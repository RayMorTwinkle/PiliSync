import 'dart:typed_data';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/watch_together/wt_player_adapter.dart';
import 'package:PiliPlus/services/watch_together/wt_playback_coordinator.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    GStorage.setting = await Hive.openBox('wt-setting', bytes: Uint8List(0));
    GStorage.video = await Hive.openBox('wt-video', bytes: Uint8List(0));
    GStorage.localCache = await Hive.openBox('wt-cache', bytes: Uint8List(0));
  });
  tearDownAll(Hive.close);

  test('adapter ignores sync pause but observes an already-paused request', () async {
    final controller = PlPlayerController.ensureInstance();
    final player = PlPlayerAdapter();
    final host = WtHostPlaybackIntent();
    final requests = <bool>[];
    final sub = player.onPlaybackRequest((playing, isInterrupt) {
      requests.add(playing);
      host.onPlaybackRequest(playing);
    });
    addTearDown(sub.cancel);
    host.updateBarrier(waiting: true, isPlaying: true);
    await player.pause();
    expect(requests, isEmpty);
    expect(
      host.reportedPaused(isPlaying: player.isPlaying, isBuffering: false),
      isFalse,
    );

    final pause = controller.pause();
    // Intent must change synchronously, before an async player status callback.
    expect(requests, [false]);
    expect(host.updateBarrier(waiting: false, isPlaying: false), isNull);
    await pause;
  });

  test(
    'pauseIfExists reports pause even when the barrier already paused',
    () async {
      final controller = PlPlayerController.ensureInstance();
      await controller.pause(isSync: true);
      final requests = <bool>[];
      final sub = PlPlayerAdapter().onPlaybackRequest(
        (playing, isInterrupt) => requests.add(playing),
      );
      addTearDown(sub.cancel);
      await PlPlayerController.pauseIfExists();
      expect(requests, [false]);
    },
  );

  test('stale playing status cannot rearm a cancelled barrier', () {
    final host = WtHostPlaybackIntent()
      ..updateBarrier(waiting: true, isPlaying: true)
      ..onPlaybackRequest(false);
    // The engine may not have completed the explicit pause yet.
    expect(host.updateBarrier(waiting: true, isPlaying: true), isNull);
    expect(host.updateBarrier(waiting: false, isPlaying: false), isNull);
  });

  test('explicit pause during the barrier cancels automatic resume', () {
    final host = WtHostPlaybackIntent()
      ..updateBarrier(waiting: true, isPlaying: true)
      ..onPlaybackRequest(false);
    expect(host.reportedPaused(isPlaying: false, isBuffering: false), isTrue);
    expect(host.updateBarrier(waiting: false, isPlaying: false), isNull);
  });

  test('resume consumes intent before a later physical pause is reported', () {
    final host = WtHostPlaybackIntent()
      ..updateBarrier(waiting: true, isPlaying: true);
    expect(host.updateBarrier(waiting: false, isPlaying: false), isTrue);
    expect(host.reportedPaused(isPlaying: true, isBuffering: false), isFalse);
    // No further member update is needed to stop overriding a later pause.
    expect(host.reportedPaused(isPlaying: false, isBuffering: false), isTrue);
    expect(host.updateBarrier(waiting: false, isPlaying: false), isNull);
  });

  test(
    'host buffering reports paused unless a barrier retains play intent',
    () {
      final host = WtHostPlaybackIntent();
      expect(host.reportedPaused(isPlaying: true, isBuffering: true), isTrue);
      host.updateBarrier(waiting: true, isPlaying: true);
      expect(host.reportedPaused(isPlaying: false, isBuffering: true), isFalse);
      host.onPlaybackRequest(false);
      expect(host.reportedPaused(isPlaying: false, isBuffering: true), isTrue);
    },
  );

  test('buffering barrier pauses physically without publishing user pause', () {
    final host = WtHostPlaybackIntent();
    expect(host.updateBarrier(waiting: true, isPlaying: true), isFalse);
    expect(host.reportedPaused(isPlaying: false, isBuffering: false), isFalse);
    expect(host.updateBarrier(waiting: true, isPlaying: false), isNull);
    expect(host.updateBarrier(waiting: false, isPlaying: false), isTrue);
    expect(host.updateBarrier(waiting: false, isPlaying: true), isNull);
  });
}
