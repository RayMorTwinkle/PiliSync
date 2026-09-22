import 'dart:typed_data';

import 'package:PiliPlus/services/telemetry/telemetry_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:hive_ce/hive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    GStorage.setting = await Hive.openBox('tel-setting', bytes: Uint8List(0));
    // 关闭遥测：init 仍会写本地计数但 ping() 短路，不发真实网络请求。
    GStorage.setting.put(SettingBoxKey.telemetryEnabled, false);
  });
  tearDownAll(Hive.close);

  test('init generates a stable device id and counts opens', () {
    Telemetry.init();
    final id = GStorage.setting.get(SettingBoxKey.telemetryDeviceId);
    expect(id, isA<String>());
    expect((id as String).isNotEmpty, isTrue);
    final firstOpen = GStorage.setting.get(SettingBoxKey.telemetryOpenCount);
    expect(firstOpen, 1);
    // Second init: same device id, open count increments.
    Telemetry.init();
    expect(GStorage.setting.get(SettingBoxKey.telemetryDeviceId), id);
    expect(GStorage.setting.get(SettingBoxKey.telemetryOpenCount), 2);
  });

  test('wt session counters accumulate and dedupe', () async {
    final before =
        GStorage.setting.get(SettingBoxKey.wtSessionCount) as int? ?? 0;
    Telemetry.wtSessionStart();
    Telemetry.wtSessionStart(); // double-start must not double-count
    await Future.delayed(const Duration(milliseconds: 1100));
    Telemetry.wtSessionEnd();
    Telemetry.wtSessionEnd(); // end without active session is a no-op
    expect(GStorage.setting.get(SettingBoxKey.wtSessionCount), before + 1);
    expect(
      GStorage.setting.get(SettingBoxKey.wtSessionSecs) as int? ?? 0,
      greaterThanOrEqualTo(1),
    );
  });
}
