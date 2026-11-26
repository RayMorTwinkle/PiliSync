import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_port.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';

/// Runs the member calibration used by the app; player and time are injectable.
class WtMemberCoordinator {
  double _lastMemberSync = -double.infinity;
  Object? _playerIdentity;
  int _generation = 0;
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
  // Loose mode far-ahead hold: a member >5s ahead of a playing room
  // pauses and waits for the host to catch up instead of seeking back —
  // a backwards seek flushes the buffer it just filled. Releases when the
  // gap shrinks below _farAheadResumeSeconds.
  bool _farAheadHold = false;
  static const _settleSeconds = 1.5;
  static const _seekLoadingSilenceSeconds = 2.0;
  static const _seekSuppressionCapSeconds = 20.0;
  static const _farBehindSeconds = 5.0;
  static const _farAheadResumeSeconds = 2.0;
  static const _catchupIntervalSeconds = 4.0;
  late WtPlayerAdapter player;
  late void Function(String) dbg;

  void reset() {
    _generation++;
    _playerIdentity = null;
    _lastMemberSync = -double.infinity;
    _memberLastSeek = null;
    _lastSeekAt = -double.infinity;
    _loadingRunStart = null;
    _lastCatchupAt = -double.infinity;
    _farAheadHold = false;
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
    final identity = player.identity;
    if (!identical(identity, _playerIdentity)) {
      reset();
      _playerIdentity = identity;
    }
    final generation = _generation;
    bool stillCurrent() =>
        generation == _generation && identical(identity, player.identity);

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
    // Mirror of farBehind for the member that is ahead (the fast-loading
    // side): pausing to wait beats a backwards seek that flushes the
    // buffer and re-triggers the loading barrier.
    final mayHold = looseSync && !room.paused && canSeek;
    final ahead = -behind;
    _farAheadHold = mayHold &&
        (ahead > _farBehindSeconds ||
            (_farAheadHold && ahead >= _farAheadResumeSeconds));
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
    if (_farAheadHold) {
      // Wait for the room to catch up — pause once, never seek back.
      action = WtSyncAction(
        play: player.isPlaying ? false : null,
        playbackRate: action.playbackRate,
      );
    }
    if (!action.isEmpty) {
      _memberLastSeek = action.seekTo;
      log(
        'CALIBRATE ${action}local=$localTime room=${room.currentTime}'
        '(${room.paused ? "paused" : "playing"})',
      );
      await _executeAction(action, player, log, stillCurrent, now);
      if (!stillCurrent()) return;
    }

    // Read AFTER commands; do not reuse the pre-seek position as readiness.
    // Seek-induced refills get a silence window: mpv flushes its buffer on
    // every sync seek, and reporting that dip would pause the whole room.
    // A far-behind member in loose mode stops holding the barrier — the
    // fluent side keeps playing while this member chases. A paused member
    // never reports: paused-by-sync buffering is background refill, and a
    // paused flag stuck true would pin the barrier and deadlock the host.
    final loading = player.isPlaying &&
        player.isBuffering &&
        !inSeekSilence(now) &&
        !farBehind;
    reportLoading(loading);
  }

  Future<void> _executeAction(
    WtSyncAction action,
    WtPlayerAdapter player,
    void Function(String) log,
    bool Function() stillCurrent,
    double now,
  ) async {
    const timeout = Duration(seconds: 3);
    if (action.seekTo != null) {
      // Even rejected catch-up attempts must respect the buffering rate limit.
      _lastCatchupAt = now;
      final elapsed = Stopwatch()..start();
      try {
        await player.seekToMs(action.seekTo! * 1000).timeout(timeout);
        if (!stillCurrent()) return;
        // Only a completed seek can justify suppressing a readiness report.
        final landed = now + elapsed.elapsedMicroseconds / 1000000;
        _lastSeekAt = landed;
        _lastCatchupAt = landed;
        _loadingRunStart = landed;
      } catch (error) {
        log('seek failed: $error');
      }
      if (!stillCurrent()) return;
    }
    if (action.playbackRate != null) {
      try {
        await player.setSpeed(action.playbackRate!).timeout(timeout);
      } catch (error) {
        log('rate failed: $error');
      }
      if (!stillCurrent()) return;
    }
    if (action.play != null) {
      try {
        final command = action.play! ? player.play() : player.pause();
        await command.timeout(timeout);
      } catch (error) {
        log('play/pause failed: $error');
      }
    }
  }
}
