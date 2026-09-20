import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:PiliPlus/services/watch_together/wt_call_manager.dart';
import 'package:PiliPlus/services/watch_together/wt_debug_server.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_adapter.dart';
import 'package:PiliPlus/services/watch_together/wt_playback_coordinator.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:PiliPlus/services/watch_together/wt_member_coordinator.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
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
  StreamSubscription<bool>? _playbackReqSub;
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
        // members have over-run and get dragged backwards). Falling edge
        // broadcasts the resume immediately.
        if (buffering) {
          _hostBufferingTimer?.cancel();
          _hostBufferingTimer = Timer(
            const Duration(seconds: 1),
            () {
              if (player.isBuffering) _hostUpdate();
            },
          );
        } else {
          _hostBufferingTimer?.cancel();
          _hostUpdate();
        }
      });
      if (player is WtPlaybackCommandSource) {
        _playbackReqSub = (player as WtPlaybackCommandSource)
            .onPlaybackRequest((playing) {
          if (role.value.isHost) {
            hostIntent.onPlaybackRequest(playing);
            _hostUpdate();
          } else if (playing &&
              room.value?.waitForLoadding == true) {
            // The member's manual play will be reverted by the next
            // calibrate while the room waits — explain instead of
            // silently fighting the user.
            final now = client.timeSync.localNow();
            if (now - _lastBarrierToast > 5) {
              _lastBarrierToast = now;
              SmartDialog.showToast('等待成员缓冲中');
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
    if (_ticking) return;
    _ticking = true;
    try {
      // Detect fake-alive sockets early (suspend/resume kills the
      // connection long before the 30s ping timeout notices).
      client.ensureAlive();
      if (role.value.isHost) {
        _ensureStatusSub();
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
    }
    _hostUpdate();
    // Host is also a member: keep its heartbeat/loading state fresh so it
    // does not vanish from memberCount or block the loading barrier.
    _memberHeartbeat();
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
    _memberHeartbeat();
    // Offline: the last snapshot is stale — extrapolating and seeking
    // from it drifts the player arbitrarily far, and reconnect then
    // snaps back with a huge jump. Freeze calibration until a fresh
    // authoritative snapshot arrives.
    if (connState.value != WtConnectionState.connected) {
      dbg('MTICK skip: offline (${connState.value})');
      return;
    }
    final snap = room.value;
    if (snap == null) return;
    if (!player.hasPlayer) {
      dbg('MTICK skip: no player (route=${Get.currentRoute})');
      return;
    }
    if (player.isLive) {
      dbg('MTICK skip: live');
      return;
    }

    await _memberCoordinator.tick(
      room: snap.playback,
      waitForLoading: snap.waitForLoadding,
      now: clock?.call() ?? client.timeSync.now(),
      player: player,
      reportLoading: _reportLoading,
      log: dbg,
      canSeek: clock != null || client.timeSync.hasValidSample,
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
    final loading = _effectiveLoading(now);
    _lastReportedLoading = loading;
    client.updateMember(loading, target: _detectTarget());
  }

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
  bool _effectiveLoading(double now) {
    final raw = player.hasPlayer && !player.isLive && player.isBuffering;
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

  void _reportLoading([bool? _]) {
    final now = clock?.call() ?? client.timeSync.now();
    final loading = _effectiveLoading(now);
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
        _applyAuthoritativeRole(event.room.isHost);
        _applyHostBarrier(event.room.waitForLoadding);
      case WtRoomUpdateEvent():
        room.value = event.room;
        _applyAuthoritativeRole(event.room.isHost);
        _applyHostBarrier(event.room.waitForLoadding);
      case WtMemberUpdateEvent():
        _handleMemberUpdate(event);
      case WtNavigateEvent():
        if (event.waitForLoadding != null) {
          _applyWaitUpdate(event.waitForLoadding!);
        }
        if (_followNavigate(event.target)) {
          SmartDialog.showToast('正在跟随房主切换视频');
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
      case WtErrorEvent():
        _handleError(event.code);
    }
  }

  void _handleMemberUpdate(WtMemberUpdateEvent event) {
    // Keep the member-side barrier fresh too: without this, members lag
    // ~2s behind the host's pause while peers are buffering.
    final snap = room.value;
    if (snap != null &&
        (snap.waitForLoadding != event.waitForLoadding ||
            snap.memberCount != event.memberCount)) {
      room.value = WtRoomSnapshot(
        name: snap.name,
        isHost: snap.isHost,
        isProtected: snap.isProtected,
        memberCount: event.memberCount,
        waitForLoadding: event.waitForLoadding,
        playback: snap.playback,
      );
    }
    _applyHostBarrier(event.waitForLoadding);
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
      _startLoop();
    } else if (!isHost && role.value.isHost) {
      role.value = WtRole.member;
      hostIntent.reset();
      _startLoop();
    }
  }

  /// Follow a host navigation only when it actually differs from the page
  /// the member is already on — reconnects must not rebuild the player.
  bool _followNavigate(WtTarget target) {
    _currentTarget = target;
    final current = _detectTarget();
    if (current != null && !_isDifferentTarget(target, current)) {
      dbg('NAV skip: already on target');
      return false;
    }
    _executeNavigate(target);
    return true;
  }

  void _applyHostBarrier(bool waiting) {
    if (!role.value.isHost || !inRoom.value || !player.hasPlayer) return;
    final resume = hostIntent.updateBarrier(
      waiting: waiting,
      isPlaying: player.hasPlayer && player.isPlaying,
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

  void _executeNavigate(WtTarget target) {
    // Only replace a page that IS a watch target. off:true on any other
    // route pops it — and popping '/' disposes MainPage, whose dispose()
    // calls GStorage.close(): every Hive box closes, the video detail
    // page dies half-loaded (title/uploader from arguments survive,
    // comments/settings reads throw) and the logger's own box read loops
    // the app into a black screen.
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
        off: off,
      );
    } else if (target.epid != null || target.seasonId != null) {
      // PGC episode with no bvid: route through the ep/ss resolver
      // instead of crashing on bv2av(null).
      PageUtils.viewPgc(
        epId: target.epid,
        seasonId: target.seasonId,
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
    await client.disconnect();
    client.timeSync.reset();
    role.value = WtRole.none;
    inRoom.value = false;
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
    _memberCoordinator.reset();
    debugLog.clear();
    call.reset();
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
