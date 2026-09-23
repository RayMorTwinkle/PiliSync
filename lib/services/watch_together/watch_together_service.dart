import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:PiliPlus/services/telemetry/telemetry_service.dart';
import 'package:PiliPlus/services/watch_together/wt_call_manager.dart';
import 'package:PiliPlus/services/watch_together/wt_debug_server.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_adapter.dart';
import 'package:PiliPlus/services/watch_together/wt_playback_coordinator.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:PiliPlus/services/watch_together/wt_member_coordinator.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

final watchTogetherService = WatchTogetherService._internal();

class WtDebugLog {
  WtDebugLog(this.t, this.msg);
  final String t;
  final String msg;
}

class WatchTogetherService {
  WatchTogetherService._internal() {
    if (kDebugMode) {
      unawaited(WtDebugServer.start());
    }
  }

  @visibleForTesting
  WatchTogetherService.forTesting({
    required this.player,
    required this.client,
    required this.clock,
  }) {
    // Tests drive ticks without a live socket — present as connected so
    // member calibration is not frozen by the offline guard.
    connState.value = WtConnectionState.connected;
  }

  /// Injectable clock for tests; falls back to the signaling time sync.
  @visibleForTesting
  double Function()? clock;

  @visibleForTesting
  Future<void> tickForTesting() => _tick();

  @visibleForTesting
  void handleEventForTesting(WtEvent event) => _handleEvent(event);

  /// Test seam for the stale-snapshot freeze: simulates the
  /// disconnected→reconnecting transition the connState listener sets.
  @visibleForTesting
  set awaitingFreshSnapshot(bool v) => _awaitingFreshSnapshot = v;

  static const _hostLoopInterval = Duration(seconds: 2);
  static const _memberLoopInterval = Duration(milliseconds: 500);

  WtSignalingClient client = WtSignalingClient();
  WtPlayerAdapter player = PlPlayerAdapter();
  final call = WtCallManager();
  final WtHostPlaybackIntent hostIntent = WtHostPlaybackIntent();

  final Rx<WtRole> role = WtRole.none.obs;
  final Rx<WtRoomSnapshot?> room = Rx<WtRoomSnapshot?>(null);
  final RxBool inRoom = false.obs;
  final RxString myTempUser = ''.obs;

  StreamSubscription<WtEvent>? _eventSub;
  StreamSubscription<WtConnectionState>? _connStateSub;
  StreamSubscription<void>? _statusSub;
  StreamSubscription<({bool playing, bool isInterrupt})>? _playbackReqSub;
  Object? _statusIdentity;
  Timer? _loop;
  bool _ticking = false;
  WtTarget? _currentTarget;
  bool _lastReportedLoading = false;

  /// Start of the player's current continuous buffering run (server-clock
  /// seconds). A member whose player stays stuck loading longer than
  /// [_loadingReportCapSeconds] stops reporting isLoading — it keeps
  /// retrying locally but no longer deadlocks the room barrier. The
  /// server enforces a longer backstop for old/buggy clients.
  double? _loadingSince;
  double? _bufferingSince;
  static const _loadingReportCapSeconds = 20.0;
  // Dwell: sub-second buffering dips (notably the refill after a
  // sync-issued seek) must not raise the room barrier and pause everyone.
  static const _loadingDwellSeconds = 1.5;
  double? _hostBufferingSince;
  static const _hostBufferingDwellSeconds = 1.0;
  Timer? _hostBufferingTimer;
  StreamSubscription<bool>? _bufferingSub;
  bool _hasJoinedOnce = false;
  double _lastDisconnectToast = -double.infinity;
  double _lastBarrierToast = -double.infinity;
  final connState = WtConnectionState.disconnected.obs;
  double _lastMemberReport = -double.infinity;
  double _lastOtherHostToast = -double.infinity;
  // Between "socket connected" and "joined/first snapshot received" the
  // cached room snapshot is stale — member calibration must stay frozen
  // until an authoritative snapshot lands on the new socket.
  bool _awaitingFreshSnapshot = false;
  // External pause (manual or audio interrupt) on the member side earns
  // a short cooldown during which calibrate will not force play again.
  double _memberPauseCooldownUntil = -double.infinity;
  // Navigate retry state: a failed/stuck member navigation is retried a
  // few times instead of silently leaving the member on the wrong page.
  bool _navigatePending = false;
  double _lastNavigateAt = -double.infinity;
  int _navigateRetries = 0;
  // Once retries are exhausted for a room target the member stays put on
  // purpose (the user keeps backing out) — snapshot drift must not re-arm
  // the same navigation. Re-arms when the room target actually changes.
  WtTarget? _navigateGiveUpTarget;
  static const _navigateRetryIntervalSeconds = 10.0;
  static const _navigateMaxRetries = 5;

  /// Test seam: intercepts the actual GetX navigation so tests can drive
  /// _followNavigate/_executeNavigate without a widget tree.
  @visibleForTesting
  void Function(WtTarget target, int? progressMs)? navigateHook;

  @visibleForTesting
  WtTarget? get currentTargetForTesting => _currentTarget;
  final _memberCoordinator = WtMemberCoordinator();
  final RxBool debugOverlay = false.obs;

  final RxList<WtDebugLog> debugLog = <WtDebugLog>[].obs;

  void dbg(String msg) {
    debugLog.add(
      WtDebugLog(
        DateTime.now().toString().substring(11, 19),
        msg,
      ),
    );
    if (debugLog.length > 60) debugLog.removeAt(0);
    debugPrint('WT_DBG $msg');
  }

  String get serverUrl =>
      GStorage.setting.get('wtServerUrl') as String? ?? 'wss://wt.raymor.top';

  /// Loose sync mode: 5s play tolerance instead of 1s, and a member that
  /// falls >5s behind stops holding the room barrier — it releases the
  /// fluent side and chases the host with rate-limited catch-up seeks.
  /// Default on: strict 1s alignment is only worth it on good networks.
  RxBool? _looseSyncRx;
  RxBool get looseSync => _looseSyncRx ??= RxBool(_readLooseSync());

  // GStorage.setting is a `late` field that unit tests never init —
  // fall back to the default rather than crashing the tick.
  bool _readLooseSync() {
    try {
      return GStorage.setting.get(SettingBoxKey.wtLooseSync,
          defaultValue: true)
              as bool? ??
          true;
    } catch (_) {
      return true;
    }
  }

  set looseSyncEnabled(bool v) {
    looseSync.value = v;
    try {
      GStorage.setting.put(SettingBoxKey.wtLooseSync, v);
    } catch (_) {}
  }

  // Host-priority mode: when on, nothing a member does can move the
  // host's player — no barrier pause, no forced resume. Members still
  // calibrate to the host as usual. Off by default (VT semantics).
  RxBool? _hostPriorityRx;
  RxBool get hostPriority =>
      _hostPriorityRx ??= RxBool(_readHostPriority());

  bool _readHostPriority() {
    try {
      return GStorage.setting.get(SettingBoxKey.wtHostPriority,
              defaultValue: false) as bool? ??
          false;
    } catch (_) {
      return false;
    }
  }

  set hostPriorityEnabled(bool v) {
    hostPriority.value = v;
    try {
      GStorage.setting.put(SettingBoxKey.wtHostPriority, v);
    } catch (_) {}
  }

  // In-room floating panel — off by default; the room page itself plus
  // this toggle are the controls.
  RxBool? _floatingPanelRx;
  RxBool get floatingPanel =>
      _floatingPanelRx ??= RxBool(_readFloatingPanel());

  bool _readFloatingPanel() {
    try {
      return GStorage.setting.get(SettingBoxKey.wtFloatingPanel,
              defaultValue: false) as bool? ??
          false;
    } catch (_) {
      return false;
    }
  }

  set floatingPanelEnabled(bool v) {
    floatingPanel.value = v;
    try {
      GStorage.setting.put(SettingBoxKey.wtFloatingPanel, v);
    } catch (_) {}
  }

  double? get memberLastSeekDebug => _memberCoordinator.lastSeek;

  set serverUrl(String value) =>
      GStorage.setting.put('wtServerUrl', value);

  Future<void> createRoom({String? server}) async {
    final roomCode = _generateRoomCode();
    await _joinInternal(
      server: server,
      room: roomCode,
      pass: '',
      newRole: WtRole.host,
    );
  }

  Future<void> joinRoom({
    String? server,
    required String room,
    required String password,
  }) async {
    await _joinInternal(
      server: server,
      room: room,
      pass: password,
      newRole: WtRole.member,
    );
  }

  Future<void> _joinInternal({
    String? server,
    required String room,
    required String pass,
    required WtRole newRole,
  }) async {
    await leave(silent: true);
    myTempUser.value = const Uuid().v4();
    // Subscribe BEFORE joining: the joined snapshot can arrive within one
    // RTT and a broadcast stream drops events with no listener.
    _listen();
    try {
      await client.connect(
        serverBase: server ?? serverUrl,
        room: room,
        user: myTempUser.value,
        pass: pass,
      );
    } catch (_) {
      SmartDialog.showToast('连接服务器失败');
      return;
    }
    // Optimistic role; the server's joined.isHost / snapshot.isHost is
    // authoritative and corrects this in _handleEvent.
    role.value = newRole;
    inRoom.value = true;
    Telemetry.wtSessionStart();
    client.join();
    _startLoop();
    call.attach(client);
    if (newRole.isHost) {
      // Room creation piggybacks on the first update — sent immediately
      // so members can join the code at once. The state is paused so an
      // uncalibrated timestamp cannot skew member extrapolation; the
      // guarded _hostUpdate overwrites it once a time sample lands.
      client.updatePlayback(
        WtPlaybackState(lastUpdateClientTime: client.timeSync.now()),
      );
    }
  }

  void _listen() {
    _eventSub = client.events.listen(_handleEvent);
    // A dropped socket invalidates every in-flight call signal — tear the
    // call down instead of leaving both sides in mismatched states until
    // the ICE timeout notices.
    _connStateSub = client.connectionState.listen((state) {
      connState.value = state;
      if (state == WtConnectionState.disconnected) {
        call.onDisconnected();
        if (inRoom.value) {
          // The next connected socket will need a fresh authoritative
          // snapshot before member calibration may resume.
          _awaitingFreshSnapshot = true;
        }
        final now = client.timeSync.localNow();
        if (inRoom.value && now - _lastDisconnectToast > 15) {
          _lastDisconnectToast = now;
          SmartDialog.showToast('一起看连接已断开，正在重连…');
        }
      } else if (state == WtConnectionState.failed) {
        SmartDialog.showToast('一起看连接失败，已退出房间');
        leave(silent: true);
      }
    });
    _ensureStatusSub();
  }

  void _ensureStatusSub() {
    if (_statusIdentity == player.identity) return;
    unawaited(_statusSub?.cancel());
    _statusSub = null;
    unawaited(_playbackReqSub?.cancel());
    _playbackReqSub = null;
    unawaited(_bufferingSub?.cancel());
    _bufferingSub = null;
    _hostBufferingTimer?.cancel();
    _hostBufferingTimer = null;
    _statusIdentity = player.identity;
    if (player.identity != null) {
      _statusSub = player.onStatusChanged((playing) {
        if (role.value.isHost) {
          _hostUpdate();
        }
      });
      _bufferingSub = player.onBufferingChanged((buffering) {
        if (!role.value.isHost) return;
        // Rising edge → broadcast the stall after the dwell confirms it
        // (instead of up to 2s later on the next tick, by which time
        // members have over-run and get dragged backwards). The dwell
        // clock must start AT the edge — seeding it inside
        // _hostBufferingDwelled at timer-fire time made the fast path
        // dead code and delayed the stall to ~3s. Falling edge
        // broadcasts the resume immediately.
        if (buffering) {
          _hostBufferingSince ??= clock?.call() ?? client.timeSync.now();
          _hostBufferingTimer?.cancel();
          _hostBufferingTimer = Timer(
            const Duration(seconds: 1),
            () {
              if (player.isBuffering) _hostUpdate();
            },
          );
        } else {
          _hostBufferingSince = null;
          _hostBufferingTimer?.cancel();
          _hostUpdate();
        }
      });
      if (player is WtPlaybackCommandSource) {
        _playbackReqSub = (player as WtPlaybackCommandSource)
            .onPlaybackRequest((playing, isInterrupt) {
          if (role.value.isHost) {
            // An audio-focus interrupt is not the user's intent to pause
            // the room — feeding it into hostIntent would permanently
            // cancel the barrier's auto-resume. The paused state itself
            // still broadcasts via reportedPaused (!isPlaying).
            if (!isInterrupt) hostIntent.onPlaybackRequest(playing);
            _hostUpdate();
          } else {
            if (!playing) {
              // External pause (manual or interrupt): calibrate must not
              // yank the member straight back to play — short cooldown.
              _memberPauseCooldownUntil =
                  (clock?.call() ?? client.timeSync.now()) + 10;
            }
            if (playing && room.value?.waitForLoadding == true) {
              // The member's manual play will be reverted by the next
              // calibrate while the room waits — explain instead of
              // silently fighting the user.
              final now = client.timeSync.localNow();
              if (now - _lastBarrierToast > 5) {
                _lastBarrierToast = now;
                SmartDialog.showToast('等待成员缓冲中');
              }
            }
          }
        });
      }
    }
  }

  void _startLoop() {
    _loop?.cancel();
    final interval = role.value.isHost
        ? _hostLoopInterval
        : _memberLoopInterval;
    _loop = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    // Heartbeat runs OUTSIDE the _ticking gate: a hung calibrate (serial
    // 3s command timeouts, up to ~9s) must not starve update_member,
    // which is the only thing keeping our membership/loading state fresh.
    _memberHeartbeat();
    // Detect fake-alive sockets early (suspend/resume kills the
    // connection long before the 30s ping timeout notices).
    client.ensureAlive();
    if (_ticking) return;
    _ticking = true;
    try {
      // Rebind player subscriptions on ticks for BOTH roles — a member's
      // rebuilt player must not leave barrier toasts/pause cooldowns
      // wired to a dead controller.
      _ensureStatusSub();
      if (role.value.isHost) {
        _hostTick();
      } else if (role.value.isMember) {
        await _memberTick();
      }
    } finally {
      _ticking = false;
    }
  }

  void _hostTick() {
    final target = _detectTarget();
    if (target != null && _isDifferentTarget(target, _currentTarget)) {
      // Only record the target once the navigate actually went out — a
      // send dropped mid-reconnect must be retried on the next tick.
      if (client.navigate(target)) {
        _currentTarget = target;
      }
    } else if (target == null && _currentTarget != null) {
      // The host left the video page entirely — a null-target navigate
      // clears the room target and tells members to pop back off the
      // stale video route.
      if (client.navigate(null)) {
        _currentTarget = null;
      }
    }
    _hostUpdate();
    // Re-evaluate the member barrier every tick: event-driven evaluation
    // alone misses the case where the host was buffering when the
    // member's loading report arrived and is only pausable afterwards.
    _applyHostBarrier(room.value?.waitForLoadding ?? false);
    // Host is also a member: heartbeat is sent from _tick outside the
    // _ticking gate so a hung calibrate cannot starve it.
  }

  void _hostUpdate() {
    if (!role.value.isHost || !inRoom.value) return;
    // Broadcasting with a bare local clock poisons every member's
    // extrapolation — hold updates until the first time sample lands
    // (HTTP sample + tsync burst, normally <1s after connect).
    if (!client.timeSync.hasValidSample) return;
    final state = _buildPlaybackState();
    if (state == null) return;
    client.updatePlayback(state);
  }
  WtPlaybackState? _buildPlaybackState() {
    final target = _currentTarget;
    final now = client.timeSync.now();
    final reportedPaused = hostIntent.reportedPaused(
      isPlaying: player.hasPlayer && player.isPlaying,
      isBuffering: player.hasPlayer && _hostBufferingDwelled(now),
    );
    if (!player.hasPlayer) {
      return WtPlaybackState(
        paused: true,
        lastUpdateClientTime: client.timeSync.now(),
        url: target?.bvid,
        videoTitle: target?.title,
        target: target,
      );
    }
    return WtPlaybackState(
      playbackRate: player.speed,
      currentTime: player.positionMs / 1000,
      duration: player.durationMs / 1000,
      paused: reportedPaused,
      lastUpdateClientTime: client.timeSync.now(),
      url: target?.bvid,
      videoTitle: target?.title,
      target: target,
    );
  }

  WtTarget? _detectTarget() {
    final route = Get.currentRoute;
    if (route == '/videoV') {
      final args = Get.arguments;
      if (args is Map && args['bvid'] != null) {
        return WtTarget(
          type: 'video',
          bvid: args['bvid'] as String?,
          cid: (args['cid'] as num?)?.toInt(),
          epid: (args['epId'] as num?)?.toInt(),
          seasonId: (args['seasonId'] as num?)?.toInt(),
          title: args['title'] as String?,
        );
      }
    }
    if (route == '/liveRoom') {
      final roomId = Get.arguments;
      if (roomId is int) {
        return WtTarget(type: 'live', roomId: roomId);
      }
    }
    return null;
  }

  bool _isDifferentTarget(WtTarget a, WtTarget? b) {
    if (b == null) return true;
    return a.type != b.type ||
        a.bvid != b.bvid ||
        a.cid != b.cid ||
        a.roomId != b.roomId ||
        a.epid != b.epid;
  }

  Future<void> _memberTick() async {
    // Offline: the last snapshot is stale — extrapolating and seeking
    // from it drifts the player arbitrarily far, and reconnect then
    // snaps back with a huge jump. Freeze calibration until a fresh
    // authoritative snapshot arrives; the ~1RTT window between socket
    // connect and `joined` still counts as stale.
    if (connState.value != WtConnectionState.connected ||
        _awaitingFreshSnapshot) {
      dbg('MTICK skip: offline/fresh (${connState.value})');
      return;
    }
    final snap = room.value;
    if (snap == null) return;
    final now = clock?.call() ?? client.timeSync.now();

    final localTarget = _detectTarget();
    final roomTarget = snap.playback.target;

    // Route recovery runs before the player checks — a half-disposed
    // player must not stall navigation away from a stale page.

    // The room has no target anymore (the host's null-navigate frame was
    // missed — e.g. it raced a reconnect) but the member still believes it
    // is on a watch page: leave it. localTarget is intentionally NOT
    // required: _exitVideoTarget checks the route itself and stays armed
    // until the watch route is actually gone.
    if (roomTarget == null && _currentTarget != null) {
      _exitVideoTarget();
      return;
    }

    // The navigate broadcast is fire-and-forget — a member whose socket
    // was dead when it went out misses it forever and stays on the old
    // video. The snapshot's target is authoritative: drift between it and
    // our followed target re-arms a navigate (unless we already gave up
    // on this exact target — do not fight the user's manual exit).
    if (roomTarget != null &&
        _isDifferentTarget(roomTarget, _currentTarget) &&
        (_navigateGiveUpTarget == null ||
            _isDifferentTarget(roomTarget, _navigateGiveUpTarget))) {
      dbg('NAV drift: refollow room target');
      _followNavigate(roomTarget);
      return;
    }

    // A failed member navigate leaves the user on the old page forever.
    // While a navigate is pending and the local page provably differs
    // (or still hasn't materialized), retry on a slow cadence.
    if (_navigatePending && _currentTarget != null) {
      final landed =
          localTarget != null &&
          !_isDifferentTarget(_currentTarget!, localTarget);
      if (landed) {
        _navigatePending = false;
        _navigateRetries = 0;
      } else if (now - _lastNavigateAt >= _navigateRetryIntervalSeconds) {
        if (_navigateRetries < _navigateMaxRetries) {
          _navigateRetries++;
          _lastNavigateAt = now;
          dbg('NAV retry #$_navigateRetries');
          _executeNavigate(
            _currentTarget!,
            progressMs: _navProgressMs(_currentTarget!),
          );
        } else {
          // Give up until the room target actually changes — do not fight
          // a user who keeps backing out of the target page.
          _navigateGiveUpTarget = _currentTarget;
          _navigatePending = false;
          _navigateRetries = 0;
          dbg('NAV gave up after $_navigateMaxRetries retries');
        }
      }
    }

    if (!player.hasPlayer) {
      dbg('MTICK skip: no player (route=${Get.currentRoute})');
      return;
    }
    if (player.isLive) {
      dbg('MTICK skip: live');
      return;
    }

    // A member on a DIFFERENT video page must not be calibrated against
    // the room's playback — that drags an unrelated player around. Only
    // skip when we can prove the mismatch (both targets known);
    // a null local target (home/watch page) keeps legacy behavior.
    if (localTarget != null &&
        roomTarget != null &&
        _isDifferentTarget(roomTarget, localTarget)) {
      dbg('MTICK skip: off-target page');
      return;
    }

    await _memberCoordinator.tick(
      room: snap.playback,
      waitForLoading: snap.waitForLoadding,
      now: now,
      player: player,
      reportLoading: _reportLoading,
      log: dbg,
      canSeek: clock != null || client.timeSync.hasValidSample,
      allowPlay: now >= _memberPauseCooldownUntil,
      looseSync: looseSync.value,
    );
  }

  /// Periodic member heartbeat (~2s, VT-aligned). Keeps server-side
  /// membership/loading alive, reports the member's actual page target so
  /// the server only counts members on the room's target, and clears a
  /// stale isLoading=true even when the member tick exits early (no
  /// player / live route), which would otherwise deadlock the room.
  void _memberHeartbeat() {
    if (!inRoom.value) return;
    final now = clock?.call() ?? client.timeSync.now();
    if (now - _lastMemberReport < 2.0) return;
    _lastMemberReport = now;
    final loading = _effectiveLoading(now, _rawLoading(now));
    _lastReportedLoading = loading;
    client.updateMember(loading, target: _detectTarget());
  }

  /// Raw member loading signal: buffering, but outside the post-seek
  /// silence window (a sync-issued seek flushes the buffer — reporting
  /// that refill as loading pauses the whole room for nothing). A paused
  /// member does not report: a player paused by sync or by hand is not
  /// actively loading, and a stuck paused-buffering flag would otherwise
  /// pin the room's barrier and deadlock the host's own load.
  bool _rawLoading(double now) =>
      player.hasPlayer &&
      !player.isLive &&
      player.isPlaying &&
      player.isBuffering &&
      !_memberCoordinator.inSeekSilence(now);

  /// Host-side dwell for the reportedPaused buffering term: mpv's
  /// buffering flag flickers on marginal networks, and every flip-flop in
  /// the broadcast `paused` makes every member pause/play in lockstep.
  bool _hostBufferingDwelled(double now) {
    if (!player.isBuffering) {
      _hostBufferingSince = null;
      return false;
    }
    final since = _hostBufferingSince ??= now;
    return now - since >= _hostBufferingDwellSeconds;
  }

  /// Maps the player's raw buffering flag to the reported loading state.
  /// Caps a continuous buffering run at [_loadingReportCapSeconds]: a
  /// member whose player never finishes loading (dead network, failed
  /// source) releases the room's barrier instead of stalling the host
  /// forever. The run timer resets whenever buffering actually clears.
  bool _effectiveLoading(double now, bool raw) {
    if (!raw) {
      _bufferingSince = null;
      _loadingSince = null;
      return false;
    }
    // Dwell first: only sustained buffering reports loading — a seek or a
    // brief underrun must not pause the whole room.
    final bufSince = _bufferingSince ??= now;
    if (now - bufSince < _loadingDwellSeconds) return false;
    final since = _loadingSince ??= now;
    return now - since <= _loadingReportCapSeconds;
  }

  /// The coordinator passes its own raw signal (buffering AND outside
  /// the post-seek silence window); dwell+cap are applied on top.
  /// Ignoring the parameter used to make the silence window dead code.
  void _reportLoading(bool raw) {
    final now = clock?.call() ?? client.timeSync.now();
    final loading = _effectiveLoading(now, raw);
    if (loading != _lastReportedLoading) {
      _lastReportedLoading = loading;
      client.updateMember(loading, target: _detectTarget());
    }
  }

  void _handleEvent(WtEvent event) {
    dbg('EVT ${event.runtimeType}');
    switch (event) {
      case WtJoinedEvent():
        room.value = event.room;
        _awaitingFreshSnapshot = false;
        _applyAuthoritativeRole(event.isHost);
        // After a reconnect the server lost our transient flags — force
        // the next heartbeat to re-report the current loading state.
        _lastReportedLoading = false;
        _lastMemberReport = -double.infinity;
        _loadingSince = null;
        // A re-join after socket reconnect must not look like a fresh
        // room create/join — that toast made users think the room died.
        SmartDialog.showToast(
          _hasJoinedOnce
              ? '已重新连接'
              : (event.isHost ? '房间已创建' : '已加入房间'),
        );
        _hasJoinedOnce = true;
        if (role.value.isMember && event.room.playback.target != null) {
          _currentTarget = event.room.playback.target;
              _followNavigate(event.room.playback.target!);
        }
      case WtUpdateAckEvent():
        room.value = event.room;
        _awaitingFreshSnapshot = false;
        _applyAuthoritativeRole(event.room.isHost);
        _applyHostBarrier(event.room.waitForLoadding);
      case WtRoomUpdateEvent():
        room.value = event.room;
        _awaitingFreshSnapshot = false;
        _applyAuthoritativeRole(event.room.isHost);
        _applyHostBarrier(event.room.waitForLoadding);
      case WtMemberUpdateEvent():
        _handleMemberUpdate(event);
      case WtNavigateEvent():
        if (event.waitForLoadding != null) {
          _applyWaitUpdate(event.waitForLoadding!);
        }
        // Only members follow — a stale navigate landing on a promoted
        // host must not steer its page.
        if (role.value.isMember) {
          if (event.target == null) {
            _exitVideoTarget();
          } else if (_followNavigate(event.target!)) {
            SmartDialog.showToast('正在跟随房主切换视频');
          }
        }
      case WtPeerEvent():
        final snap = room.value;
        if (snap != null) {
          room.value = WtRoomSnapshot(
            name: snap.name,
            isHost: snap.isHost,
            isProtected: snap.isProtected,
            memberCount: event.memberCount,
            waitForLoadding: event.waitForLoadding ?? snap.waitForLoadding,
            playback: snap.playback,
          );
        }
        if (event.waitForLoadding != null) {
          _applyHostBarrier(event.waitForLoadding!);
        }
        if (!event.joined) {
          call.onPeerLeft(event.tempUser);
        }
        SmartDialog.showToast(
          event.joined ? '成员加入房间' : '成员离开房间',
        );
      case WtWebRTCEvent():
        unawaited(call.onSignal(event));
      case WtChatEvent():
        break;
      case WtTransferRequestEvent():
        _showTransferRequest(event.from);
      case WtTransferRequestedEvent():
        SmartDialog.showToast('已向房主发送申请');
      case WtTransferDeniedEvent():
        SmartDialog.showToast('房主拒绝了转让申请');
      case WtHostChangedEvent():
        // The role flip itself arrives via the room snapshot's per-conn
        // isHost (handled by _applyAuthoritativeRole); this is just UX.
        SmartDialog.showToast(
          event.to == client.tempUser ? '你已成为房主' : '房主已变更',
        );
      case WtErrorEvent():
        _handleError(event.code);
    }
  }

  /// Member → ask the host for the host role.
  void requestHostTransfer() {
    if (!inRoom.value || !role.value.isMember) return;
    if (!client.requestHostTransfer()) {
      SmartDialog.showToast('连接已断开，无法发送申请');
    }
  }

  /// Host → hand the role to [to] ('peer' = the sole other member).
  void transferHostTo([String to = 'peer']) {
    if (!inRoom.value || !role.value.isHost) return;
    if (!client.transferHost(to)) {
      SmartDialog.showToast('连接已断开，无法转让');
    }
  }

  void _showTransferRequest(String from) {
    if (!role.value.isHost) return; // a stale request for the old host
    SmartDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('房主转让申请'),
        content: const Text('有成员申请成为房主，是否同意？'),
        actions: [
          TextButton(
            onPressed: () {
              SmartDialog.dismiss();
              client.denyTransfer(from);
            },
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () {
              SmartDialog.dismiss();
              transferHostTo(from);
            },
            child: const Text('同意转让'),
          ),
        ],
      ),
    );
  }

  void _handleMemberUpdate(WtMemberUpdateEvent event) {
    // Keep the member-side barrier fresh too: without this, members lag
    // ~2s behind the host's pause while peers are buffering. The field
    // is nullable: an older server that omits it must not be read as
    // "barrier cleared" (?? false would erase a live barrier).
    final waiting = event.waitForLoadding;
    final snap = room.value;
    if (snap != null &&
        ((waiting != null && snap.waitForLoadding != waiting) ||
            snap.memberCount != event.memberCount)) {
      room.value = WtRoomSnapshot(
        name: snap.name,
        isHost: snap.isHost,
        isProtected: snap.isProtected,
        memberCount: event.memberCount,
        waitForLoadding: waiting ?? snap.waitForLoadding,
        playback: snap.playback,
      );
    }
    if (waiting != null) {
      _applyHostBarrier(waiting);
    }
  }

  /// Fold a barrier value carried by a non-snapshot message (navigate /
  /// peer events) into the room snapshot and the host barrier.
  void _applyWaitUpdate(bool waiting) {
    final snap = room.value;
    if (snap != null && snap.waitForLoadding != waiting) {
      room.value = WtRoomSnapshot(
        name: snap.name,
        isHost: snap.isHost,
        isProtected: snap.isProtected,
        memberCount: snap.memberCount,
        waitForLoadding: waiting,
        playback: snap.playback,
      );
    }
    _applyHostBarrier(waiting);
  }

  /// The server is authoritative on host status. Promote/demote whenever
  /// a snapshot disagrees with the optimistic local role.
  void _applyAuthoritativeRole(bool isHost) {
    if (isHost && !role.value.isHost) {
      role.value = WtRole.host;
      // Promotion to host: member-side residue (pause cooldown, seek
      // settle windows, the loading run clock) would leak into host
      // logic. Refresh _currentTarget from the actual page — a member
      // who wandered off the room target must not broadcast it.
      _memberPauseCooldownUntil = -double.infinity;
      _memberCoordinator.reset();
      _currentTarget = _detectTarget() ?? _currentTarget;
      _reportLoading(false);
      _startLoop();
    } else if (!isHost && role.value.isHost) {
      role.value = WtRole.member;
      hostIntent.reset();
      // Demoted: drop host-side buffering state so a stale dwell clock
      // or pending edge timer cannot fire into the member role.
      _hostBufferingSince = null;
      _hostBufferingTimer?.cancel();
      _hostBufferingTimer = null;
      _startLoop();
    }
  }

  /// The host left the video page: drop the stale target and pop the
  /// member's video route if it is still sitting on it. An overlay/sheet
  /// on top of the video page may not register its own route name — a
  /// single back() can leave the video still mounted, so _currentTarget
  /// stays armed until the route provably left the watch pages and the
  /// member tick keeps popping.
  void _exitVideoTarget() {
    _navigatePending = false;
    _navigateRetries = 0;
    _navigateGiveUpTarget = null;
    final route = Get.currentRoute;
    if (route == '/videoV' || route == '/liveRoom') {
      Get.back();
    } else {
      _currentTarget = null;
    }
  }

  /// Follow a host navigation only when it actually differs from the page
  /// the member is already on — reconnects must not rebuild the player.
  bool _followNavigate(WtTarget target) {
    _currentTarget = target;
    _navigateGiveUpTarget = null;
    // A room-driven navigation starts a fresh sync context: a pause
    // cooldown armed on the previous page (manual pause, audio
    // interrupt, or a leaked setDataSource pause) must not carry over
    // and block auto-play on the new video.
    _memberPauseCooldownUntil = -double.infinity;
    final current = _detectTarget();
    if (current != null && !_isDifferentTarget(target, current)) {
      dbg('NAV skip: already on target');
      _navigatePending = false;
      _navigateRetries = 0;
      return false;
    }
    _navigatePending = true;
    _navigateRetries = 0;
    _lastNavigateAt = clock?.call() ?? client.timeSync.now();
    _executeNavigate(target, progressMs: _navProgressMs(target));
    return true;
  }

  /// Position to open a followed page at: the room's extrapolated
  /// position when the target matches the authoritative snapshot (the
  /// member then buffers straight at the room position instead of
  /// opening at local history and double-filling the cache on the
  /// sync seek). A new target starts at 0 — passing it explicitly also
  /// suppresses the page's own history-resume seek.
  int _navProgressMs(WtTarget target) {
    final snap = room.value?.playback;
    if (snap?.target == null || _isDifferentTarget(target, snap!.target!)) {
      return 0;
    }
    final secs = client.timeSync.hasValidSample
        ? WtPlaybackLogic.extrapolateCurrent(snap, client.timeSync.now())
        : snap.currentTime;
    return (secs * 1000).round();
  }

  void _applyHostBarrier(bool waiting) {
    if (!role.value.isHost || !inRoom.value || !player.hasPlayer) return;
    // Host-priority mode: member state never moves the host's player —
    // no barrier pause, and since none was ever issued, no resume either.
    if (hostPriority.value) return;
    final resume = hostIntent.updateBarrier(
      waiting: waiting,
      // A buffering host is not really playing — pausing it gains nothing
      // and on engines where pause stalls the demuxer it would deadlock
      // the host's own load behind the member barrier. The barrier still
      // engages on the next tick once the host is actually playing.
      isPlaying:
          player.hasPlayer && player.isPlaying && !player.isBuffering,
    );
    final now = client.timeSync.localNow();
    if (resume == false) {
      player.pause();
      // Fires on each forced pause — including the revert after the host
      // manually pressed play during the barrier, which is exactly the
      // moment the "why did it pause" explanation is needed.
      if (now - _lastBarrierToast > 5) {
        _lastBarrierToast = now;
        SmartDialog.showToast('成员缓冲中，已暂停等待');
      }
    } else if (resume == true) {
      player.play();
      if (now - _lastBarrierToast > 5) {
        _lastBarrierToast = now;
        SmartDialog.showToast('成员已就绪，继续播放');
      }
    }
  }

  void _executeNavigate(WtTarget target, {int? progressMs}) {
    // Only replace a page that IS a watch target. off:true on any other
    // route pops it — and popping '/' disposes MainPage, whose dispose()
    // calls GStorage.close(): every Hive box closes, the video detail
    // page dies half-loaded (title/uploader from arguments survive,
    // comments/settings reads throw) and the logger's own box read loops
    // the app into a black screen.
    final hook = navigateHook;
    if (hook != null) {
      hook(target, progressMs);
      return;
    }
    final route = Get.currentRoute;
    final off = route == '/videoV' || route == '/liveRoom';
    if (target.isLive) {
      PageUtils.toLiveRoom(target.roomId, off: off);
    } else if (target.bvid != null) {
      PageUtils.toVideoPage(
        bvid: target.bvid,
        cid: target.cid ?? 0,
        epId: target.epid,
        seasonId: target.seasonId,
        title: target.title,
        progress: progressMs,
        // wtFollow forces autoplay on the destination page: Pref's
        // autoPlayEnable defaults to false, and without it the engine is
        // never created — the member stays "phantom playing" forever.
        extraArguments: const {'wtFollow': true},
        off: off,
      );
    } else if (target.epid != null || target.seasonId != null) {
      // PGC episode with no bvid: route through the ep/ss resolver
      // instead of crashing on bv2av(null).
      PageUtils.viewPgc(
        epId: target.epid,
        seasonId: target.seasonId,
        progress: progressMs,
        extraArguments: const {'wtFollow': true},
        off: off,
      );
    }
  }

  void _handleError(String code) {
    switch (code) {
      case 'room_closed':
      case 'room_not_exist':
        if (role.value.isHost) {
          _currentTarget = null;
          _hostUpdate();
          // A fresh createRoom hits room_not_exist on join before the
          // first update auto-creates it — that path is expected, not a
          // rebuild worth toasting about.
          if (room.value != null) {
            SmartDialog.showToast('房间已重建');
          }
        } else {
          SmartDialog.showToast(
            code == 'room_not_exist' ? '房间不存在或已过期' : '房间已关闭',
          );
          leave(silent: true);
        }
      case 'wrong_password':
        SmartDialog.showToast('房间密码错误');
        leave(silent: true);
      case 'room_full':
        SmartDialog.showToast('房间已满');
        leave(silent: true);
      case 'already_bound':
      case 'identity_in_use':
        // Another live connection owns our tempUser identity — staying
        // would split the room's view of us; leave instead of looping.
        SmartDialog.showToast('身份冲突，已退出房间');
        leave(silent: true);
      case 'not_in_room':
        // Server no longer has our membership (restart, raced reconnect,
        // upsert self-heal failed): every heartbeat would just earn
        // another not_in_room — leave cleanly instead of zombie-looping.
        SmartDialog.showToast('房间状态异常，已退出');
        leave(silent: true);
      case 'other_host_syncing':
        // We lost authority: stop acting as host instead of retrying the
        // rejected update every 2s and spamming toasts.
        if (role.value.isHost) {
          role.value = WtRole.member;
          hostIntent.reset();
          _startLoop();
          SmartDialog.showToast('已有其他房主在同步');
        } else {
          final now = client.timeSync.now();
          if (now - _lastOtherHostToast > 10) {
            _lastOtherHostToast = now;
            SmartDialog.showToast('已有其他房主在同步');
          }
        }
      default:
        SmartDialog.showToast('一起看错误: $code');
    }
  }

  String _generateRoomCode() {
    final random = Random.secure();
    return List.generate(6, (_) => random.nextInt(10)).join();
  }

  Future<void> leave({bool silent = false}) async {
    _loop?.cancel();
    _loop = null;
    await _eventSub?.cancel();
    await _connStateSub?.cancel();
    _connStateSub = null;
    await _statusSub?.cancel();
    _eventSub = null;
    _statusSub = null;
    await _playbackReqSub?.cancel();
    _playbackReqSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    _statusIdentity = null;
    // Send the WebRTC bye BEFORE the socket goes down — resetting after
    // disconnect made the send a guaranteed drop and left the peer in
    // "calling" until the ICE timeout noticed.
    call.reset();
    await client.disconnect();
    client.timeSync.reset();
    role.value = WtRole.none;
    inRoom.value = false;
    Telemetry.wtSessionEnd();
    room.value = null;
    connState.value = WtConnectionState.disconnected;
    _currentTarget = null;
    hostIntent.reset();
    _hasJoinedOnce = false;
    _lastReportedLoading = false;
    _lastMemberReport = -double.infinity;
    _lastOtherHostToast = -double.infinity;
    _lastDisconnectToast = -double.infinity;
    _lastBarrierToast = -double.infinity;
    _loadingSince = null;
    _bufferingSince = null;
    _hostBufferingSince = null;
    _hostBufferingTimer?.cancel();
    _hostBufferingTimer = null;
    _awaitingFreshSnapshot = false;
    _memberPauseCooldownUntil = -double.infinity;
    _navigatePending = false;
    _navigateRetries = 0;
    _navigateGiveUpTarget = null;
    _memberCoordinator.reset();
    debugLog.clear();
    if (!silent) {
      SmartDialog.showToast('已退出一起看');
    }
  }

  void navigateToCurrent() {
    if (!role.value.isHost) return;
    // The button lives on the room page where _detectTarget sees nothing —
    // fall back to the last detected target (kept fresh by _hostTick).
    final target = _detectTarget() ?? _currentTarget;
    if (target != null && client.navigate(target)) {
      _currentTarget = target;
    }
  }
}
