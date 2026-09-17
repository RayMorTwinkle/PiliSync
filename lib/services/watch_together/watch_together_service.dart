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
  });

  /// Injectable clock for tests; falls back to the signaling time sync.
  @visibleForTesting
  double Function()? clock;

  @visibleForTesting
  Future<void> tickForTesting() => _tick();

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
  StreamSubscription<void>? _statusSub;
  StreamSubscription<bool>? _playbackReqSub;
  Object? _statusIdentity;
  Timer? _loop;
  bool _ticking = false;
  WtTarget? _currentTarget;
  bool _lastReportedLoading = false;
  final _memberCoordinator = WtMemberCoordinator();
  bool debugOverlay = false;

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
      GStorage.setting.get('wtServerUrl') as String? ?? '127.0.0.1:9901';

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
    role.value = newRole;
    inRoom.value = true;
    _listen();
    _startLoop();
    call.attach(client);
    if (newRole.isHost) {
      client.updatePlayback(
        WtPlaybackState(lastUpdateClientTime: client.timeSync.now()),
      );
    }
  }

  void _listen() {
    _eventSub = client.events.listen(_handleEvent);
    _ensureStatusSub();
  }

  void _ensureStatusSub() {
    if (_statusIdentity == player.identity) return;
    unawaited(_statusSub?.cancel());
    _statusSub = null;
    unawaited(_playbackReqSub?.cancel());
    _playbackReqSub = null;
    _statusIdentity = player.identity;
    if (player.identity != null) {
      _statusSub = player.onStatusChanged((playing) {
        if (role.value.isHost) {
          _hostUpdate();
        }
      });
      if (player is WtPlaybackCommandSource) {
        _playbackReqSub = (player as WtPlaybackCommandSource)
            .onPlaybackRequest((playing) {
          if (role.value.isHost) {
            hostIntent.onPlaybackRequest(playing);
            _hostUpdate();
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
    debugPrint('WT_TICK route=${Get.currentRoute} args=${Get.arguments.runtimeType} target=${target?.bvid ?? target?.roomId} current=${_currentTarget?.bvid}');
    if (target != null && _isDifferentTarget(target, _currentTarget)) {
      _currentTarget = target;
      client.navigate(target);
    }
    _hostUpdate();
  }

  void _hostUpdate() {
    if (!role.value.isHost || !inRoom.value) return;
    final state = _buildPlaybackState();
    if (state == null) return;
    client.updatePlayback(state);
  }
  WtPlaybackState? _buildPlaybackState() {
    final target = _currentTarget;
    final reportedPaused = hostIntent.reportedPaused(
      isPlaying: player.hasPlayer && player.isPlaying,
      isBuffering: player.hasPlayer && player.isBuffering,
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
    );
  }

  void _reportLoading([bool? forced]) {
    final loading = forced ?? player.isBuffering;
    if (loading != _lastReportedLoading) {
      _lastReportedLoading = loading;
      client.updateMember(loading);
    }
  }

  void _handleEvent(WtEvent event) {
    dbg('EVT ${event.runtimeType}');
    switch (event) {
      case WtJoinedEvent():
        room.value = event.room;
        SmartDialog.showToast(event.isHost ? '房间已创建' : '已加入房间');
        if (role.value.isMember && event.room.playback.target != null) {
          _currentTarget = event.room.playback.target;
          _executeNavigate(event.room.playback.target!);
        }
      case WtUpdateAckEvent():
        room.value = event.room;
      case WtRoomUpdateEvent():
        room.value = event.room;
        if (event.room.hostId == myTempUser.value && role.value.isMember) {
          role.value = WtRole.host;
          _startLoop();
        }
      case WtMemberUpdateEvent():
        _handleMemberUpdate(event);
      case WtNavigateEvent():
        SmartDialog.showToast('正在跟随房主切换视频');
        _executeNavigate(event.target);
      case WtPeerEvent():
        final snap = room.value;
        if (snap != null) {
          room.value = WtRoomSnapshot(
            name: snap.name,
            hostId: snap.hostId,
            isProtected: snap.isProtected,
            memberCount: event.memberCount,
            waitForLoadding: snap.waitForLoadding,
            playback: snap.playback,
          );
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
    if (!role.value.isHost) return;
    final resume = hostIntent.updateBarrier(
      waiting: event.waitForLoadding,
      isPlaying: player.hasPlayer && player.isPlaying,
    );
    if (resume == false) {
      player.pause();
    } else if (resume == true) {
      player.play();
    }
  }

  void _executeNavigate(WtTarget target) {
    if (target.isLive) {
      PageUtils.toLiveRoom(target.roomId, off: true);
    } else {
      PageUtils.toVideoPage(
        bvid: target.bvid,
        cid: target.cid ?? 0,
        title: target.title,
        off: true,
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
          SmartDialog.showToast('房间已重建');
        } else {
          SmartDialog.showToast('房间已关闭或过期');
          leave(silent: true);
        }
      case 'wrong_password':
        SmartDialog.showToast('房间密码错误');
        leave(silent: true);
      case 'other_host_syncing':
        SmartDialog.showToast('已有其他房主在同步');
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
    await _statusSub?.cancel();
    _eventSub = null;
    _statusSub = null;
    await _playbackReqSub?.cancel();
    _playbackReqSub = null;
    _statusIdentity = null;
    await client.disconnect();
    client.timeSync.reset();
    role.value = WtRole.none;
    inRoom.value = false;
    room.value = null;
    _currentTarget = null;
    hostIntent.reset();
    _lastReportedLoading = false;
    _memberCoordinator.reset();
    debugLog.clear();
    call.reset();
    if (!silent) {
      SmartDialog.showToast('已退出一起看');
    }
  }

  void navigateToCurrent() {
    if (!role.value.isHost) return;
    final target = _detectTarget();
    if (target != null) {
      _currentTarget = target;
      client.navigate(target);
    }
  }
}
