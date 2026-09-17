import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ready member waits while a late loading member can start playback', () {
    const room = WtPlaybackState(paused: false, currentTime: 10);
    WtSyncAction calibrate({required bool loading}) => WtPlaybackLogic.calibrate(
      room: room,
      localPaused: loading,
      localTime: 10,
      localRate: 1,
      roomRealTime: 10,
      waitForLoadding: true,
      isSettling: false,
      isThisMemberLoading: loading,
    );

    expect(calibrate(loading: false).play, isFalse);
    expect(calibrate(loading: true).play, isTrue);
  });
}
