import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/watch_together/watch_together_service.dart';
import 'package:PiliPlus/services/watch_together/wt_player_adapter.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Debug-only control plane (kDebugMode builds): lets an external test
/// driver drive the watch-together feature and read full app state via
/// HTTP instead of UI automation. Compiled out of release builds.
class WtDebugServer {
  WtDebugServer._();

  static HttpServer? _server;
  static const port = 9911;

  static Future<void> start() async {
    if (_server != null) return;
    try {
      // Loopback only: this control plane can seek/navigate/join rooms
      // with a password in the query — it must not be reachable from the
      // LAN on a debug build running on a real device. Use `adb forward`
      // for remote debugging.
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: true,
      );
      _server!.listen(
        (req) => unawaited(_handle(req)),
        onError: (Object e) => debugPrint('WT_DEBUG_SRV error: $e'),
      );
      debugPrint('WT_DEBUG_SRV listening on :$port');
    } catch (e) {
      debugPrint('WT_DEBUG_SRV bind failed: $e');
    }
  }

  static Future<void> _handle(HttpRequest req) async {
    final sw = Stopwatch()..start();
    String result = 'ok';
    try {
      result = await _route(req);
    } catch (e) {
      result = 'error: $e';
    }
    final body = jsonEncode({
      'result': result,
      'ms': sw.elapsedMilliseconds,
    });
    req.response.headers.contentType = ContentType.json;
    req.response.write(body);
    await req.response.close();
    debugPrint('WT_DEBUG_SRV ${req.method} ${req.uri} -> $result');
  }

  static Future<String> _route(HttpRequest req) async {
    final path = req.uri.path;
    final q = req.uri.queryParameters;
    final svc = watchTogetherService;

    if (path == '/status') {
      return jsonEncode(_snapshot(svc));
    }
    if (path == '/wt/create') {
      if (q['server'] != null) svc.serverUrl = q['server']!;
      await svc.createRoom();
      return 'room=${svc.room.value?.name}';
    }
    if (path == '/wt/join') {
      final room = q['room'];
      if (room == null) return 'missing room';
      if (q['server'] != null) svc.serverUrl = q['server']!;
      await svc.joinRoom(room: room, password: q['pwd'] ?? '');
      return 'joined room=$room';
    }
    if (path == '/wt/leave') {
      await svc.leave();
      return 'left';
    }
    if (path == '/navigate') {
      final bvid = q['bvid'];
      if (bvid == null) return 'missing bvid';
      final cid = int.tryParse(q['cid'] ?? '') ?? 0;
      PageUtils.toVideoPage(
        bvid: bvid,
        cid: cid,
        title: q['title'] ?? '',
        // off:true on '/' pops MainPage → dispose() closes every Hive box
        // → half-loaded detail page + logger crash loop. Push instead.
        off: Get.currentRoute == '/videoV',
      );
      return 'navigating $bvid';
    }
    if (path == '/play') {
      // With autoplay off the engine only exists after a user tap on the
      // cover — replicate that tap via playerInit so /play is not a no-op.
      final p = svc.player;
      if (p is PlPlayerAdapter &&
          PlPlayerController.instance?.videoPlayerController == null) {
        final tag = (Get.arguments as Map?)?['heroTag'];
        final vdc = tag != null && Get.isRegistered<VideoDetailController>(tag: tag)
            ? Get.find<VideoDetailController>(tag: tag)
            : null;
        if (vdc != null) {
          unawaited(vdc.playerInit(autoplay: true));
          return 'playerInit triggered';
        }
      }
      await svc.player.play().timeout(const Duration(seconds: 3));
      return 'play sent';
    }
    if (path == '/pause') {
      await svc.player.pause().timeout(const Duration(seconds: 3));
      return 'pause sent';
    }
    if (path == '/seek') {
      final t = double.tryParse(q['t'] ?? '');
      if (t == null) return 'missing t';
      await svc.player.seekToMs(t * 1000).timeout(const Duration(seconds: 3));
      return 'seek ${t}s';
    }
    if (path == '/speed') {
      final v = double.tryParse(q['v'] ?? '');
      if (v == null) return 'missing v';
      await svc.player.setSpeed(v).timeout(const Duration(seconds: 3));
      return 'speed $v';
    }
    if (path == '/back') {
      Get.back();
      return 'back -> ${Get.currentRoute}';
    }
    if (path == '/call/start') {
      unawaited(svc.call.start(q['peer'] ?? 'peer'));
      return 'call starting';
    }
    if (path == '/call/hangup') {
      unawaited(svc.call.hangUp());
      return 'hangup';
    }
    if (path == '/call/mic') {
      svc.call.toggleMic();
      return 'micMuted=${svc.call.micMuted}';
    }
    if (path == '/call/gate') {
      final v = double.tryParse(q['v'] ?? '');
      if (v == null) return 'missing v';
      svc.call.gateThresholdValue = v;
      return 'gate=$v';
    }
    if (path == '/call/vol') {
      final v = double.tryParse(q['v'] ?? '');
      if (v == null) return 'missing v';
      svc.call.remoteVolumeValue = v;
      return 'vol=$v';
    }
    if (path == '/wt/loose') {
      final v = q['v'];
      if (v == null) return 'missing v';
      svc.looseSyncEnabled = v == '1';
      return 'loose=${svc.looseSync.value}';
    }
    if (path == '/wt/hostPriority') {
      final v = q['v'];
      if (v == null) return 'missing v';
      svc.hostPriorityEnabled = v == '1';
      return 'hostPriority=${svc.hostPriority.value}';
    }
    if (path == '/navigateLive') {
      final roomId = int.tryParse(q['roomId'] ?? '');
      if (roomId == null) return 'missing roomId';
      PageUtils.toLiveRoom(roomId, off: Get.currentRoute == '/liveRoom');
      return 'navigating live $roomId';
    }
    return 'unknown path $path';
  }

  static Map<String, dynamic> _snapshot(WatchTogetherService svc) {
    final room = svc.room.value;
    final snap = <String, dynamic>{
      'route': Get.currentRoute,
      'role': svc.role.value.name,
      'inRoom': svc.inRoom.value,
      'conn': svc.client.state.name,
      'serverUrl': svc.serverUrl,
      'tsync': {
        'offset': svc.client.timeSync.offset,
        'minTrip': svc.client.timeSync.hasValidSample
            ? svc.client.timeSync.minTrip
            : null,
      },
      'room': room == null
          ? null
          : {
              'name': room.name,
              'members': room.memberCount,
              'waitForLoadding': room.waitForLoadding,
              'playback': {
                'currentTime': room.playback.currentTime,
                'paused': room.playback.paused,
                'rate': room.playback.playbackRate,
                'duration': room.playback.duration,
                'url': room.playback.url,
                'title': room.playback.videoTitle,
                'lastUpdateClientTime': room.playback.lastUpdateClientTime,
              },
            },
      'player': {
        'hasPlayer': svc.player.hasPlayer,
        'isPlaying': svc.player.hasPlayer ? svc.player.isPlaying : null,
        'isBuffering': svc.player.hasPlayer ? svc.player.isBuffering : null,
        'positionSec': svc.player.hasPlayer
            ? svc.player.positionMs / 1000
            : null,
        'durationSec': svc.player.hasPlayer
            ? svc.player.durationMs / 1000
            : null,
        'speed': svc.player.hasPlayer ? svc.player.speed : null,
        'isLive': svc.player.hasPlayer ? svc.player.isLive : null,
      },
      'memberLastSeek': svc.memberLastSeekDebug,
      'call': {
        'state': svc.call.state.name,
        'micMuted': svc.call.micMuted,
        'micLevel': svc.call.micLevel.value,
        'gate': svc.call.gateThreshold.value,
        'gateOpen': svc.call.gateOpenForTesting,
        'remoteVol': svc.call.remoteVolume.value,
      },
      'logs': svc.debugLog
          .take(30)
          .map((l) => '${l.t} ${l.msg}')
          .toList(),
    };
    return snap;
  }
}
