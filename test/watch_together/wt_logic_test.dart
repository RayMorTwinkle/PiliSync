import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WtTimeSync', () {
    test('adopts offset from min-RTT sample only', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(1000.0, 100.0, 102.0);
      expect(sync.offset, closeTo(899.0, 0.001));
      expect(sync.minTrip, 2.0);

      sync.updateIfNeeded(2000.0, 200.0, 210.0);
      expect(sync.offset, closeTo(899.0, 0.001));

      sync.updateIfNeeded(3000.0, 300.0, 300.2);
      expect(sync.offset, closeTo(2699.9, 0.001));
    });

    test('now() applies offset to local clock', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(5000.0, 10.0, 10.5);
      final before = DateTime.now().millisecondsSinceEpoch / 1000;
      final n = sync.now();
      final after = DateTime.now().millisecondsSinceEpoch / 1000;
      expect(n, greaterThanOrEqualTo(before + 4989.0));
      expect(n, lessThanOrEqualTo(after + 4990.0));
    });

    test('negative trip ignored', () {
      final sync = WtTimeSync();
      sync.updateIfNeeded(100.0, 50.0, 40.0);
      expect(sync.hasValidSample, isFalse);
    });
  });

  group('WtPlaybackLogic.extrapolateCurrent', () {
    test('paused returns currentTime as-is', () {
      final state = WtPlaybackState(
        currentTime: 30,
        paused: true,
        playbackRate: 2,
        lastUpdateClientTime: 100,
      );
      expect(WtPlaybackLogic.extrapolateCurrent(state, 200), 30);
    });

    test('playing extrapolates by rate', () {
      final state = WtPlaybackState(
        currentTime: 30,
        paused: false,
        playbackRate: 2,
        lastUpdateClientTime: 100,
      );
      expect(WtPlaybackLogic.extrapolateCurrent(state, 105), 40);
    });
  });

  group('WtPlaybackLogic.calibrate', () {
    WtPlaybackState room({
      required bool paused,
      double currentTime = 100,
      double rate = 1,
      double lastClient = 1000,
    }) => WtPlaybackState(
      paused: paused,
      currentTime: currentTime,
      playbackRate: rate,
      lastUpdateClientTime: lastClient,
    );

    test('playing small drift -> no action', () {
      final r = room(paused: false, currentTime: 100);
      final action = WtPlaybackLogic.calibrate(
        room: r,
        waitForLoadding: false,
        isSettling: false,
        localPaused: false,
        localTime: 100.5,
        localRate: 1,
        roomRealTime: 100.5,
      );
      expect(action.isEmpty, isTrue);
    });

    test('playing large drift -> seek', () {
      final r = room(paused: false, currentTime: 100);
      final action = WtPlaybackLogic.calibrate(
        room: r,
        waitForLoadding: false,
        isSettling: false,
        localPaused: false,
        localTime: 102.0,
        localRate: 1,
        roomRealTime: 100.0,
      );
      expect(action.seekTo, 100.0);
    });

    test('paused small drift -> seek', () {
      final r = room(paused: true, currentTime: 100);
      final action = WtPlaybackLogic.calibrate(
        room: r,
        waitForLoadding: false,
        isSettling: false,
        localPaused: true,
        localTime: 100.2,
        localRate: 1,
        roomRealTime: 100,
      );
      expect(action.seekTo, 100.0);
    });

    test('paused state mismatch -> play/pause', () {
      final r = room(paused: false);
      final action = WtPlaybackLogic.calibrate(
        room: r,
        waitForLoadding: false,
        isSettling: false,
        localPaused: true,
        localTime: 100.0,
        localRate: 1,
        roomRealTime: 100.0,
      );
      expect(action.play, isTrue);
    });

    test('rate mismatch -> rate', () {
      final r = room(paused: false, rate: 2);
      final action = WtPlaybackLogic.calibrate(
        room: r,
        waitForLoadding: false,
        isSettling: false,
        localPaused: false,
        localTime: 100.0,
        localRate: 1,
        roomRealTime: 100.0,
      );
      expect(action.playbackRate, 2);
    });

    test('waitForLoadding forces member pause', () {
      final r = room(paused: false, currentTime: 100);
      final action = WtPlaybackLogic.calibrate(
        room: r,
        waitForLoadding: true,
        isSettling: false,
        localPaused: false,
        localTime: 100.0,
        localRate: 1,
        roomRealTime: 100.0,
      );
      expect(action.play, isFalse);
    });

    test('settling suppresses repeated seek', () {
      final r = room(paused: false, currentTime: 100);
      final action = WtPlaybackLogic.calibrate(
        room: r,
        waitForLoadding: false,
        isSettling: true,
        localPaused: false,
        localTime: 50.0,
        localRate: 1,
        roomRealTime: 100.0,
      );
      expect(action.isEmpty, isTrue);
    });
  });

  group('models', () {
    test('WtPlaybackState json roundtrip', () {
      final state = WtPlaybackState(
        playbackRate: 1.5,
        currentTime: 42.5,
        duration: 600,
        paused: false,
        lastUpdateClientTime: 1000,
        lastUpdateServerTime: 1001,
        url: 'https://example.com',
        videoTitle: 't',
        target: const WtTarget(type: 'video', bvid: 'BV1', cid: 1),
      );
      final parsed = WtPlaybackState.fromJson(state.toJson());
      expect(parsed.currentTime, 42.5);
      expect(parsed.playbackRate, 1.5);
      expect(parsed.paused, isFalse);
      expect(parsed.target!.bvid, 'BV1');
      expect(parsed.target!.cid, 1);
    });

    test('WtRoomSnapshot flattens playback fields', () {
      final snap = WtRoomSnapshot.fromJson({
        'name': 'r1',
        'hostId': 'h1',
        'protected': true,
        'memberCount': 2,
        'waitForLoadding': false,
        'playbackRate': 1.0,
        'currentTime': 55.0,
        'paused': false,
        'lastUpdateClientTime': 999,
      });
      expect(snap.name, 'r1');
      expect(snap.isProtected, isTrue);
      expect(snap.playback.currentTime, 55.0);
      expect(snap.playback.lastUpdateClientTime, 999);
    });
  });
}
