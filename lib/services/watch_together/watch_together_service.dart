import 'dart:async';
import 'dart:math';

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_adapter.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

final watchTogetherService = WatchTogetherService._internal();

class WatchTogetherService {
  WatchTogetherService._internal();

  static const _hostLoopInterval = Duration(seconds: 2);
  static const _memberLoopInterval = Duration(milliseconds: 500);

  WtSignalingClient client = WtSignalingClient();
  WtPlayerAdapter player = PlPlayerAdapter();

  final Rx<WtRole> role = WtRole.none.obs;
  final Rx<WtRoomSnapshot?> room = Rx<WtRoomSnapshot?>(null);
  final RxBool inRoom = false.obs;
  final RxString myTempUser = ''.obs;

  StreamSubscription<WtEvent>? _eventSub;
  StreamSubscription<void>? _statusSub;
  Timer? _loop;
  WtTarget? _currentTarget;
  bool _resumeAfterLoading = false;
  bool _lastReportedLoading = false;

  String get serverUrl =>
      GStorage.setting.get('wtServerUrl') as String? ?? '127.0.0.1:9901';

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
        isHost: newRole.isHost,
      );
    } catch (_) {
      SmartDialog.showToast('连接服务器失败');
      return;
    }
    role.value = newRole;
    inRoom.value = true;
    _listen();
    _startLoop();
  }

  void _listen() {
    _eventSub = client.events.listen(_handleEvent);
    _statusSub = player.onStatusChanged((playing) {
      if (role.value.isHost) {
        _hostUpdate(immediate: true);
      }
    });
  }

  void _startLoop() {
    _loop?.cancel();
    final interval = role.value.isHost
        ? _hostLoopInterval
        : _memberLoopInterval;
    _loop = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (role.value.isHost) {
      _hostTick();
    } else if (role.value.isMember) {
      await _memberTick();
    }
  }

  void _hostTick() {
    final target = _detectTarget();
    if (target != null && _isDifferentTarget(target, _currentTarget)) {
      _currentTarget = target;
      client.navigate(target);
    }
    _hostUpdate();
  }

  void _hostUpdate({bool immediate = false}) {
    if (!role.value.isHost || !inRoom.value) return;
    final state = _buildPlaybackState();
    if (state == null) return;
    client.updatePlayback(state);
  }

  WtPlaybackState? _buildPlaybackState() {
    if (!player.hasPlayer) return null;
    final target = _currentTarget;
    return WtPlaybackState(
      playbackRate: player.speed,
      currentTime: player.positionMs / 1000,
      duration: player.durationMs / 1000,
      paused: !player.isPlaying,
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
    return a.type != b.type || a.bvid != b.bvid || a.roomId != b.roomId ||
        a.epid != b.epid;
  }

  Future<void> _memberTick() async {
    final snap = room.value;
    if (snap == null || !player.hasPlayer || player.isLive) return;
    final now = client.timeSync.now();
    final roomRealTime = WtPlaybackLogic.extrapolateCurrent(snap.playback, now);
    final action = WtPlaybackLogic.calibrate(
      room: snap.playback,
      localPaused: !player.isPlaying,
      localTime: player.positionMs / 1000,
      localRate: player.speed,
      roomRealTime: roomRealTime,
    );
    if (!action.isEmpty) {
      await _executeAction(action);
    }
    _reportLoading();
  }

  Future<void> _executeAction(WtSyncAction action) async {
    if (action.seekTo != null) {
      await player.seekToMs(action.seekTo! * 1000);
    }
    if (action.playbackRate != null) {
      await player.setSpeed(action.playbackRate!);
    }
    if (action.play != null) {
      if (action.play!) {
        await player.play();
      } else {
        await player.pause();
      }
    }
  }

  void _reportLoading() {
    final loading = player.isBuffering;
    if (loading != _lastReportedLoading) {
      _lastReportedLoading = loading;
      client.updateMember(loading);
    }
  }

  void _handleEvent(WtEvent event) {
    switch (event) {
      case WtJoinedEvent():
        room.value = event.room;
        SmartDialog.showToast(event.isHost ? '房间已创建' : '已加入房间');
      case WtUpdateAckEvent():
        room.value = event.room;
      case WtRoomUpdateEvent():
        room.value = event.room;
        if (event.room.hostId == myTempUser.value) {
          role.value = WtRole.host;
        }
      case WtMemberUpdateEvent():
        _handleMemberUpdate(event);
      case WtNavigateEvent():
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
        SmartDialog.showToast(
          event.joined ? '成员加入房间' : '成员离开房间',
        );
      case WtWebRTCEvent():
        break;
      case WtChatEvent():
        break;
      case WtErrorEvent():
        _handleError(event.code);
    }
  }

  void _handleMemberUpdate(WtMemberUpdateEvent event) {
    if (!role.value.isHost) return;
    if (event.waitForLoadding) {
      if (player.isPlaying) {
        _resumeAfterLoading = true;
        player.pause();
      }
    } else if (_resumeAfterLoading) {
      _resumeAfterLoading = false;
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
      case 'room_not_exist':
        SmartDialog.showToast('房间不存在或已过期');
      case 'wrong_password':
        SmartDialog.showToast('房间密码错误');
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
    await client.disconnect();
    client.timeSync.reset();
    role.value = WtRole.none;
    inRoom.value = false;
    room.value = null;
    _currentTarget = null;
    _resumeAfterLoading = false;
    _lastReportedLoading = false;
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
