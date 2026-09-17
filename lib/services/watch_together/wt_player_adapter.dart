import 'dart:async';

import 'package:PiliPlus/services/watch_together/wt_player_port.dart';
export 'package:PiliPlus/services/watch_together/wt_player_port.dart';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';

/// Optional command source, independent of playback status notifications.
abstract interface class WtPlaybackCommandSource {
  StreamSubscription<bool> onPlaybackRequest(void Function(bool playing) cb);
}

class PlPlayerAdapter implements WtPlayerAdapter, WtPlaybackCommandSource {
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
  Future<void> play() async => _p?.play(isSync: true);

  @override
  Future<void> pause() async => _p?.pause(isSync: true);

  /// Subscribe again when [identity] changes, just like status notifications.
  @override
  StreamSubscription<bool> onPlaybackRequest(void Function(bool playing) cb) =>
      (_p?.playbackRequests ?? const Stream<bool>.empty()).listen(cb);

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
