import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:uuid/v4.dart';

/// 遥测：每次启动向服务端 POST 一次 ping（可在「其他设置」底部关闭）。
/// 只收集：设备 ID、版本、登录账号 mid/uname、打开次数、一起看次数与时长。
/// IP 与属地由服务端从请求推导，客户端不传。
abstract final class Telemetry {
  static String? _deviceId;
  static int _openCount = 0;
  static bool _wtActive = false;
  static int _wtSessionStart = 0;

  /// 启动时调用一次（GStorage 就绪后）。不阻塞、任何失败静默。
  static void init() {
    try {
      _deviceId =
          GStorage.setting.get(SettingBoxKey.telemetryDeviceId) as String?;
      if (_deviceId == null || _deviceId!.isEmpty) {
        _deviceId = const UuidV4().generate();
        GStorage.setting.put(SettingBoxKey.telemetryDeviceId, _deviceId);
      }
      _openCount =
          (GStorage.setting.get(SettingBoxKey.telemetryOpenCount)
              as int? ??
          0) +
          1;
      GStorage.setting.put(SettingBoxKey.telemetryOpenCount, _openCount);
    } catch (e) {
      if (kDebugMode) debugPrint('telemetry init: $e');
      return;
    }
    ping();
  }

  /// 进入一起看房间（建房或进房成功）时调用。
  static void wtSessionStart() {
    if (_wtActive) return;
    _wtActive = true;
    _wtSessionStart = DateTime.now().millisecondsSinceEpoch;
    try {
      final n =
          (GStorage.setting.get(SettingBoxKey.wtSessionCount) as int? ?? 0) +
          1;
      GStorage.setting.put(SettingBoxKey.wtSessionCount, n);
    } catch (_) {}
  }

  /// 离开一起看房间时调用。崩溃时本会话时长丢失（可接受，
  /// 次数已在上面的 start 里持久化）。
  static void wtSessionEnd() {
    if (!_wtActive) return;
    _wtActive = false;
    final secs =
        (DateTime.now().millisecondsSinceEpoch - _wtSessionStart) ~/ 1000;
    try {
      final total =
          (GStorage.setting.get(SettingBoxKey.wtSessionSecs) as int? ?? 0) +
          secs;
      GStorage.setting.put(SettingBoxKey.wtSessionSecs, total);
    } catch (_) {}
  }

  static Future<void> ping() async {
    try {
      if (_deviceId == null || !Pref.telemetryEnabled) return;
      int mid = 0;
      String uname = '';
      try {
        if (Accounts.main.isLogin) {
          mid = Accounts.main.mid;
          uname = Pref.userInfoCache?.uname ?? '';
        }
      } catch (_) {}
      await Request().post(
        Api.telemetryPing,
        data: {
          'device_id': _deviceId,
          'version': BuildConfig.versionName,
          'build_time': BuildConfig.buildTime,
          'mid': mid,
          'uname': uname,
          'open_count': _openCount,
          'wt_count':
              GStorage.setting.get(SettingBoxKey.wtSessionCount) as int? ?? 0,
          'wt_secs':
              GStorage.setting.get(SettingBoxKey.wtSessionSecs) as int? ?? 0,
        },
        options: Options(extra: {'account': const NoAccount()}),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('telemetry ping: $e');
    }
  }
}
