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
  // Loose mode: a member >5s behind stops reporting loading (releases the
  // room barrier) and may seek through buffering — rate-limited so a slow
  // network is not asked to refetch every tick.
  double _lastCatchupAt = -double.infinity;
  static const _settleSeconds = 1.5;
  static const _seekLoadingSilenceSeconds = 2.0;
  static const _seekSuppressionCapSeconds = 20.0;
  static const _farBehindSeconds = 5.0;
  static const _catchupIntervalSeconds = 4.0;
  late WtPlayerAdapter player;
  late void Function(String) dbg;

  void reset() {
    _lastMemberSync = 0;
    _memberLastSeek = null;
    _lastSeekAt = -double.infinity;
    _loadingRunStart = null;
    _lastCatchupAt = -double.infinity;
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
    // Loose sync: 5s play tolerance; a member >5s behind releases the
    // barrier and chases with rate-limited catch-up seeks.
    bool looseSync = false,
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
    // Loose mode: a member >5s behind a PLAYING room stops holding the
    // barrier (its loading is no longer reported) and may issue catch-up
    // seeks even while buffering — rate-limited to one per interval so a
    // chronically slow member is not told to refetch constantly. Only
    // meaningful once a valid time sample exists (canSeek gate below).
    final behind = roomRealTime - localTime;
    // canSeek doubles as the "valid clock domain" gate: without a time
    // sample roomRealTime is extrapolated from a meaningless `now`, and a
    // garbage farBehind would wrongly mute the member's loading report.
    final farBehind =
        looseSync && !room.paused && canSeek && behind > _farBehindSeconds;
    final catchupReady =
        farBehind &&
        !isSettling &&
        now - _lastCatchupAt >= _catchupIntervalSeconds;
    final suppressSeek =
        player.isBuffering && loadingRun < _seekSuppressionCapSeconds &&
        !catchupReady;

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
      playingThreshold: looseSync ? _farBehindSeconds : null,
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
      } else {
        // any successful non-seek round clears the pending-seek marker
        _memberLastSeek = null;
      }
      dbg(
        'CALIBRATE ${action}local=$localTime room=${room.currentTime}'
        '(${room.paused ? "paused" : "playing"})',
      );
      // Measure when the seek actually lands: settle/silence must start
      // then, not at issue time — a 3s-timeout seek issued with _lastSeekAt
      // at tick time would silently shorten the protection window.
      final sw = Stopwatch()..start();
      await _executeAction(action);
      if (action.seekTo != null) {
        final landed = now + sw.elapsedMilliseconds / 1000;
        _lastSeekAt = landed;
        _lastCatchupAt = landed;
        // The seek discards whatever buffer accumulated — restart the
        // exemption run so the next allowed realign is another cap away.
        _loadingRunStart = landed;
      }
    }

    // Read AFTER commands; do not reuse the pre-seek position as readiness.
    // Seek-induced refills get a silence window: mpv flushes its buffer on
    // every sync seek, and reporting that dip would pause the whole room.
    // A far-behind member in loose mode stops holding the barrier — the
    // fluent side keeps playing while this member chases.
    final loading =
        player.isBuffering && !inSeekSilence(now) && !farBehind;
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
