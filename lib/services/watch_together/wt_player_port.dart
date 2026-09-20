import 'dart:async';

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

  /// Buffering-edge notifications (host uses them to broadcast stalls
  /// immediately instead of waiting for the next 2s tick).
  StreamSubscription<bool> onBufferingChanged(void Function(bool buffering) cb);
}

