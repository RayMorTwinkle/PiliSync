import 'package:PiliPlus/services/watch_together/wt_models.dart';

class WtTimeSync {
  double _offset = 0;
  double _minTrip = double.infinity;

  static const _maxSamples = 8;
  final List<double> _trips = [];

  double get offset => _offset;
  double get minTrip => _minTrip;
  bool get hasValidSample => _minTrip < double.infinity;

  double localNow() => DateTime.now().millisecondsSinceEpoch / 1000;

  double now() => localNow() + _offset;

  void updateIfNeeded(num serverTimestamp, num start, num end) {
    final trip = (end - start).toDouble();
    if (trip < 0) return;
    _trips.add(trip);
    if (_trips.length > _maxSamples) _trips.removeAt(0);
    if (trip >= _minTrip) return;
    _minTrip = trip;
    _offset = serverTimestamp - (start + end) / 2;
  }

  void reset() {
    _offset = 0;
    _minTrip = double.infinity;
    _trips.clear();
  }
}

class WtPlaybackLogic {
  static const playingSeekThreshold = 1.0;
  static const pausedSeekThreshold = 0.1;

  static double extrapolateCurrent(
    WtPlaybackState room,
    double nowSeconds,
  ) {
    if (room.paused) return room.currentTime;
    return room.currentTime +
        (nowSeconds - room.lastUpdateClientTime) * room.playbackRate;
  }

  static WtSyncAction calibrate({
    required WtPlaybackState room,
    required bool localPaused,
    required double localTime,
    required double localRate,
    required double roomRealTime,
  }) {
    double? seekTo;
    bool? play;
    double? rate;

    if (room.paused != localPaused) {
      play = !room.paused;
    }

    final target = room.paused ? room.currentTime : roomRealTime;
    final diff = (localTime - target).abs();
    final threshold = room.paused ? pausedSeekThreshold : playingSeekThreshold;
    if (diff > threshold) {
      seekTo = target;
    }

    if ((room.playbackRate - localRate).abs() > 0.001) {
      rate = room.playbackRate;
    }

    return WtSyncAction(seekTo: seekTo, play: play, playbackRate: rate);
  }
}
