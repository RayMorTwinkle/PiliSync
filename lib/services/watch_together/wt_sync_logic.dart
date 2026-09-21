import 'package:PiliPlus/services/watch_together/wt_models.dart';

class WtTimeSync {
  double _offset = 0;
  double _minTrip = double.infinity;

  double get offset => _offset;
  double get minTrip => _minTrip;
  bool get hasValidSample => _minTrip < double.infinity;

  double localNow() => DateTime.now().millisecondsSinceEpoch / 1000;

  double now() => localNow() + _offset;

  /// [start] and [end] must be the same local clock (send/receive times);
  /// [serverTimestamp] is the remote clock. Never mix the two domains.
  void updateIfNeeded(num serverTimestamp, num start, num end) {
    final trip = (end - start).toDouble();
    if (trip < 0) return;
    if (trip >= _minTrip) return;
    _minTrip = trip;
    _offset = serverTimestamp - (start + end) / 2;
  }

  void reset() {
    _offset = 0;
    _minTrip = double.infinity;
  }
}

class WtPlaybackLogic {
  static const playingSeekThreshold = 1.0;
  static const pausedSeekThreshold = 0.1;

  /// Extrapolated position, clamped to [0, duration] so clock skew can
  /// never produce an out-of-range seek target.
  static double extrapolateCurrent(
    WtPlaybackState room,
    double nowSeconds,
  ) {
    var t = room.currentTime;
    if (!room.paused) {
      t += (nowSeconds - room.lastUpdateClientTime) * room.playbackRate;
    }
    if (t < 0) return 0;
    if (room.duration > 0 && t > room.duration) return room.duration;
    return t;
  }

  /// Align to the host intent. A loading member must keep loading, while
  /// ready members wait. Settling suppresses repeated seeks, never play/pause.
  static WtSyncAction calibrate({
    required WtPlaybackState room,
    required bool localPaused,
    required double localTime,
    required double localRate,
    required double roomRealTime,
    required bool waitForLoadding,
    required bool isSettling,
    bool isThisMemberLoading = false,
    // Overrides the loading-based seek suppression. The caller applies a
    // run-length cap: a member whose buffering flag never clears still
    // gets an occasional realign instead of drifting forever.
    bool? suppressSeek,
    // False during a post-external-pause cooldown (manual pause / audio
    // interrupt): suppress auto-play, never auto-pause.
    bool allowPlay = true,
  }) {
    double? seekTo;
    bool? play;
    double? rate;

    bool paused = room.paused;
    if (waitForLoadding && !paused && !isThisMemberLoading) {
      paused = true;
    }

    if (paused != localPaused) {
      play = !paused;
    }
    if (!allowPlay && play == true) {
      play = null;
    }

    final target = paused ? room.currentTime : roomRealTime;
    final diff = (localTime - target).abs();
    final threshold = paused ? pausedSeekThreshold : playingSeekThreshold;
    // A buffering member must not seek: the seek discards the buffer it
    // is filling, restarting the load and extending the room barrier —
    // the lag-amplification loop. It realigns in one shot once ready.
    final blockSeek = suppressSeek ?? isThisMemberLoading;
    if (!isSettling && !blockSeek && diff > threshold) {
      seekTo = target;
    }

    if ((room.playbackRate - localRate).abs() > 0.001) {
      rate = room.playbackRate;
    }

    return WtSyncAction(seekTo: seekTo, play: play, playbackRate: rate);
  }
}
