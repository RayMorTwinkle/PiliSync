import 'dart:async';

import 'package:PiliPlus/services/watch_together/wt_player_port.dart';
export 'package:PiliPlus/services/watch_together/wt_player_port.dart';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';

/// Optional command source, independent of playback status notifications.
/// [isInterrupt] marks system-level pauses (audio focus loss, phone call)
/// that must not be treated as the user's intent to pause the room.
abstract interface class WtPlaybackCommandSource {
  StreamSubscription<({bool playing, bool isInterrupt})> onPlaybackRequest(
    void Function(bool playing, bool isInterrupt) cb,
  );
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
  // 毫秒精度：整秒 position 与外推小数目标叠加会把 <1s 的稳态偏差
  // 量化成 >1s 的 diff，周期性误触发 seek（且每次 seek 清空弹幕）。
  double get positionMs => (_p?.positionInMilliseconds ?? 0).toDouble();

  @override
  double get durationMs => (_p?.durationInMilliseconds ?? 0).toDouble();

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
  StreamSubscription<({bool playing, bool isInterrupt})> onPlaybackRequest(
    void Function(bool playing, bool isInterrupt) cb,
  ) => (_p?.playbackRequests ?? const Stream.empty()).listen(
    (req) => cb(req.playing, req.isInterrupt),
  );

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

  @override
  StreamSubscription<bool> onBufferingChanged(void Function(bool buffering) cb) {
    final p = PlPlayerController.instance;
    if (p == null) {
      return const Stream<bool>.empty().listen(null);
    }
    return p.isBuffering.listen(cb);
  }
}
