/// Pure playback coordination, independent of Flutter and the player engine.
class WtHostPlaybackIntent {
  bool _resumeAfterLoading = false;
  bool _barrierCancelled = false;

  /// Non-sync playback requests override the barrier's remembered intent.
  /// In particular, pause must be observed even when already physically paused.
  void onPlaybackRequest(bool playing) {
    _barrierCancelled = !playing;
    if (!playing) _resumeAfterLoading = false;
  }

  bool? updateBarrier({required bool waiting, required bool isPlaying}) {
    if (!waiting) _barrierCancelled = false;
    if (waiting && isPlaying && !_barrierCancelled) {
      _resumeAfterLoading = true;
      return false;
    }
    if (!waiting && _resumeAfterLoading) {
      _resumeAfterLoading = false;
      if (!isPlaying) return true;
    }
    return null;
  }

  bool reportedPaused({required bool isPlaying, required bool isBuffering}) {
    if (_resumeAfterLoading) return false;
    // VT treats an unloaded host as paused, except while the barrier owns play.
    return !isPlaying || isBuffering;
  }

  void reset() {
    _resumeAfterLoading = false;
    _barrierCancelled = false;
  }
}
