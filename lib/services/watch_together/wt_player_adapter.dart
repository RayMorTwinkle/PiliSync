import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';

abstract interface class WtPlayerAdapter {
  bool get hasPlayer;
  bool get isPlaying;
  bool get isBuffering;
  double get positionMs;
  double get durationMs;
  double get speed;
  bool get isLive;
  Object? get identity;

  Future<void> play();
  Future<void> pause();
  Future<void> seekToMs(double ms);
  Future<void> setSpeed(double speed);

  StreamSubscription<void> onStatusChanged(void Function(bool playing) cb);
}

class PlPlayerAdapter implements WtPlayerAdapter {
  PlPlayerController? get _p => PlPlayerController.instance;

  @override
  bool get hasPlayer => _p != null;

  @override
  bool get isPlaying => _p?.playerStatus.isPlaying ?? false;

  @override
  bool get isBuffering => _p?.isBuffering.value ?? false;

  @override
  double get positionMs => (_p?.position.value ?? 0) * 1000;

  @override
  double get durationMs => (_p?.duration.value ?? 0) * 1000;

  @override
  double get speed => _p?.playbackSpeed ?? 1.0;

  @override
  bool get isLive => _p?.isLive ?? false;

  @override
  Object? get identity => _p;

  @override
  Future<void> play() async => _p?.play();

  @override
  Future<void> pause() async => _p?.pause();

  @override
  Future<void> seekToMs(double ms) async =>
      _p?.seekTo(Duration(milliseconds: ms.round()));

  @override
  Future<void> setSpeed(double speed) async => _p?.setPlaybackSpeed(speed);

  @override
  StreamSubscription<void> onStatusChanged(void Function(bool playing) cb) {
    final p = PlPlayerController.instance;
    if (p == null) {
      return const Stream<void>.empty().listen(null);
    }
    return p.playerStatus.listen((status) => cb(status.isPlaying));
  }
}
