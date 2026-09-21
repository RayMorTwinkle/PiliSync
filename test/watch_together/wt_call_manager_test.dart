import 'dart:async';

import 'package:PiliPlus/services/watch_together/wt_call_manager.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingSignaling extends WtSignalingClient {
  final signals = <({String to, Map<String, dynamic> payload})>[];
  @override
  bool sendWebRTC(String to, Map<String, dynamic> payload) {
    signals.add((to: to, payload: payload));
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reset sends bye to the bound peer and clears call state', () {
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);
    call.seedForTesting(peerId: 'peer-A', state: WtCallState.connected);

    call.reset();

    expect(client.signals, hasLength(1));
    expect(client.signals.single.to, 'peer-A');
    expect(client.signals.single.payload['kind'], 'bye');
    expect(call.state, WtCallState.idle);
    expect(call.micMuted, isFalse);
    expect(call.speakerOn, isTrue);
  });

  test('idle reset sends no bye', () {
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);

    call.reset();
    expect(client.signals, isEmpty);
  });

  test('signals from a different sender are dropped once bound', () async {
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);
    call.seedForTesting(peerId: 'peer-A', state: WtCallState.connected);

    // A stranger's bye must not kill our call.
    await call.onSignal(
      const WtWebRTCEvent('peer-B', {'kind': 'bye'}),
    );
    expect(call.state, WtCallState.connected);

    // Our own peer's bye tears the call down (and bye is echoed back).
    await call.onSignal(
      const WtWebRTCEvent('peer-A', {'kind': 'bye'}),
    );
    expect(call.state, WtCallState.idle);
  });

  test('unbound non-offer signals are ignored while idle', () async {
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);

    await call.onSignal(
      const WtWebRTCEvent('someone', {'kind': 'ice', 'candidate': 'c'}),
    );
    await call.onSignal(
      const WtWebRTCEvent('someone', {'kind': 'bye'}),
    );
    expect(call.state, WtCallState.idle);
    expect(client.signals, isEmpty);
  });

  test('onPeerLeft only tears down when it is our peer', () {
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);
    call.seedForTesting(peerId: 'peer-A', state: WtCallState.connected);

    call.onPeerLeft('peer-B');
    expect(call.state, WtCallState.connected);

    call.onPeerLeft('peer-A');
    expect(call.state, WtCallState.idle);
    expect(client.signals.single.payload['kind'], 'bye');
  });

  test('socket disconnect fails the call and releases resources', () {
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);
    call.seedForTesting(peerId: 'peer-A', state: WtCallState.calling);

    call.onDisconnected();
    expect(call.state, WtCallState.failed);

    // idle call manager is unaffected by socket churn
    final idle = WtCallManager()..attach(client);
    idle.onDisconnected();
    expect(idle.state, WtCallState.idle);
  });

  test('start on a dead socket fails immediately instead of wedging (F12-f)', () {
    // Previously start() entered `calling` and awaited offer creation —
    // a dead socket meant the offer never went out and nothing ever
    // timed out: permanent `calling`.
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);

    unawaited(call.start('peer-A'));

    expect(call.state, WtCallState.failed);
    expect(client.signals, isEmpty, reason: 'no offer on a dead socket');
  });

  test('unbound calling alias resets when the sole peer leaves (F12-f)', () {
    // The offer was sent to the "host" alias; the peer_left event names
    // the real uuid — a strict equality check would keep us in calling
    // forever. Unbound → any departure resets.
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final call = WtCallManager()..attach(client);
    call.seedForTesting(peerId: 'host', state: WtCallState.calling);

    call.onPeerLeft('the-real-uuid');

    expect(call.state, WtCallState.idle);
    expect(client.signals.single.payload['kind'], 'bye');
  });
group('voice gate', () {
  test('threshold 0 keeps the gate always open', () {
    final call = WtCallManager();
    call.gateThresholdValue = 0;
    call.onMicLevelForTesting(0.0);
    expect(call.gateOpenForTesting, isTrue);
    call.onMicLevelForTesting(0.001);
    expect(call.gateOpenForTesting, isTrue);
  });

  test('gate closes below threshold and reopens above it', () {
    final call = WtCallManager();
    call.gateThresholdValue = 0.1;
    call.onMicLevelForTesting(0.05);
    expect(call.gateOpenForTesting, isFalse);
    // Hysteresis: still closed at 0.08 (between 0.06 close and 0.1 open).
    call.onMicLevelForTesting(0.08);
    expect(call.gateOpenForTesting, isFalse);
    call.onMicLevelForTesting(0.15);
    expect(call.gateOpenForTesting, isTrue);
    // Hysteresis: stays open until below 0.6 * threshold.
    call.onMicLevelForTesting(0.07);
    expect(call.gateOpenForTesting, isTrue);
    call.onMicLevelForTesting(0.02);
    expect(call.gateOpenForTesting, isFalse);
  });

  test('lowering the threshold to 0 while closed reopens the gate', () {
    final call = WtCallManager();
    call.gateThresholdValue = 0.1;
    call.onMicLevelForTesting(0.01);
    expect(call.gateOpenForTesting, isFalse);
    call.gateThresholdValue = 0;
    call.onMicLevelForTesting(0.0);
    expect(call.gateOpenForTesting, isTrue);
  });
});
}
