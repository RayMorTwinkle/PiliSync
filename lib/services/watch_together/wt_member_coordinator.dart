import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_port.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';

/// Runs the member calibration used by the app; player and time are injectable.
class WtMemberCoordinator {
  double _lastMemberSync = 0;
  double? _memberLastSeek;
  double? get lastSeek => _memberLastSeek;
  // Settling window after a seek: suppresses repeated seeks while the
  // player converges (paused-seek precision is coarse).
  double _lastSeekAt = -double.infinity;
  // Start of the player's current continuous buffering run — the seek
  // exemption is capped just like the loading report is, otherwise a
  // permanently-stuck buffering flag would also block realignment.
  double? _loadingRunStart;
  static const _settleSeconds = 1.5;
  static const _seekLoadingSilenceSeconds = 2.0;
  static const _seekSuppressionCapSeconds = 20.0;
  late WtPlayerAdapter player;
  late void Function(String) dbg;

  void reset() {
    _lastMemberSync = 0;
    _memberLastSeek = null;
    _lastSeekAt = -double.infinity;
    _loadingRunStart = null;
  }

  /// True while inside the post-seek silence window — a sync-issued seek
  /// flushes the player's buffer, and that refill must not be reported
  /// as member loading. Shared with the service's heartbeat path.
  bool inSeekSilence(double now) =>
      now - _lastSeekAt < _seekLoadingSilenceSeconds;

  Future<void> tick({
    required WtPlaybackState room,
    required bool waitForLoading,
    required double now,
    required WtPlayerAdapter player,
    required void Function(bool) reportLoading,
    required void Function(String) log,
    // Without a valid time sample the room timestamp and the local clock
    // are in different domains — pause/play decisions still work (they do
    // not depend on positions) but seeks must be suppressed.
    bool canSeek = true,
    // False during the member's post-external-pause cooldown (manual
    // pause or audio interrupt): suppress auto-play, never auto-pause.
    bool allowPlay = true,
  }) async {
    this.player = player;
    dbg = log;
    // VT: 1s throttle between member syncs (vt.js:3463)
    if (now - _lastMemberSync < 1.0) return;
    _lastMemberSync = now;

    final roomRealTime = WtPlaybackLogic.extrapolateCurrent(
      room,
      now,
    );
    final localTime = player.positionMs / 1000;

    // mpv exposes buffering directly. A stationary paused video is ready,
    // not evidence of buffering, and must remain able to receive play().
    _memberLastSeek = null;
    final isSettling = now - _lastSeekAt < _settleSeconds;

    // The buffering seek exemption is capped at the same bound as the
    // loading report: a wedged player that never finishes buffering
    // would otherwise be exempt from realigning seeks forever.
    if (player.isBuffering) {
      _loadingRunStart ??= now;
    } else {
      _loadingRunStart = null;
    }
    final loadingRun = _loadingRunStart == null
        ? 0.0
        : now - _loadingRunStart!;
    final suppressSeek =
        player.isBuffering && loadingRun < _seekSuppressionCapSeconds;

    var action = WtPlaybackLogic.calibrate(
      room: room,
      localPaused: !player.isPlaying,
      localTime: localTime,
      localRate: player.speed,
      roomRealTime: roomRealTime,
      waitForLoadding: waitForLoading,
      isThisMemberLoading: player.isBuffering,
      isSettling: isSettling,
      suppressSeek: suppressSeek,
      allowPlay: allowPlay,
    );
    if (!canSeek && action.seekTo != null) {
      dbg('SEEK suppressed: no valid time sample');
      action = WtSyncAction(
        play: action.play,
        playbackRate: action.playbackRate,
      );
    }
    if (!action.isEmpty) {
      if (action.seekTo != null) {
        _memberLastSeek = action.seekTo!;
        _lastSeekAt = now;
        // The seek discards whatever buffer accumulated — restart the
        // exemption run so the next allowed realign is another cap away.
        _loadingRunStart = now;
      } else {
        // any successful non-seek round clears the pending-seek marker
        _memberLastSeek = null;
      }
      dbg(
        'CALIBRATE ${action}local=$localTime room=${room.currentTime}'
        '(${room.paused ? "paused" : "playing"})',
      );
      await _executeAction(action);
    }

    // Read AFTER commands; do not reuse the pre-seek position as readiness.
    // Seek-induced refills get a silence window: mpv flushes its buffer on
    // every sync seek, and reporting that dip would pause the whole room.
    final loading = player.isBuffering && !inSeekSilence(now);
    reportLoading(loading);
  }

  Future<void> _executeAction(WtSyncAction action) async {
    const timeout = Duration(seconds: 3);
    if (action.seekTo != null) {
      try {
        await player.seekToMs(action.seekTo! * 1000).timeout(timeout);
      } catch (e) {
        dbg('seek timeout: $e');
      }
    }
    if (action.playbackRate != null) {
      try {
        await player.setSpeed(action.playbackRate!).timeout(timeout);
      } catch (e) {
        dbg('rate timeout: $e');
      }
    }
    if (action.play != null) {
      try {
        if (action.play!) {
          await player.play().timeout(timeout);
        } else {
          await player.pause().timeout(timeout);
        }
      } catch (e) {
        dbg('playpause timeout: $e');
      }
    }
  }

}
