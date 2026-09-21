import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as fwr;
import 'package:get/get.dart' hide navigator;

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

enum WtCallState { idle, calling, connected, failed }

class WtCallManager {
  WtCallManager();

  final _state = WtCallState.idle.obs;
  final _micMuted = false.obs;
  final _speakerOn = true.obs;
  // Live mic level (0..1) from outbound RTP stats — drives the UI meter.
  final micLevel = 0.0.obs;
  // Voice gate threshold (0 = off). Below it the audio track is disabled
  // entirely — not just attenuated — so quiet noise is never transmitted.
  // Lazy: GStorage is not ready at singleton construction.
  RxDouble? _gateRx;
  RxDouble get gateThreshold => _gateRx ??= RxDouble(_readGatePref());
  bool _gateOpen = true;
  Timer? _gateTimer;

  double _readGatePref() {
    try {
      return (GStorage.setting.get(SettingBoxKey.wtVoiceGate,
              defaultValue: 0.0)
              as num?)
          ?.toDouble() ??
          0.0;
    } catch (_) {
      return 0.0;
    }
  }

  set gateThresholdValue(double v) {
    gateThreshold.value = v;
    try {
      GStorage.setting.put(SettingBoxKey.wtVoiceGate, v);
    } catch (_) {}
    _applyMicEnabled();
  }

  fwr.RTCPeerConnection? _pc;
  fwr.MediaStream? _localStream;
  fwr.MediaStream? _remoteStream;
  String? _peerId;
  WtSignalingClient? _client;
  // Answer timeout: without it a dropped offer or a peer that never
  // answers leaves the state in "calling" forever (no ICE is created
  // that could time out, so nothing else ever fires).
  Timer? _answerTimer;
  static const _answerTimeout = Duration(seconds: 15);

  // Signaling events are processed strictly in arrival order so an ICE
  // candidate can never overtake the offer/answer it depends on.
  Future<void> _signalWork = Future<void>.value();
  bool _hasRemoteDescription = false;
  final List<fwr.RTCIceCandidate> _pendingCandidates = [];

  WtCallState get state => _state.value;
  bool get micMuted => _micMuted.value;
  bool get speakerOn => _speakerOn.value;
  fwr.MediaStream? get remoteStream => _remoteStream;

  void attach(WtSignalingClient client) {
    _client = client;
  }

  void reset() {
    if (_peerId != null && _state.value != WtCallState.idle) {
      _sendSignal({'kind': 'bye'});
    }
    _teardown();
    _state.value = WtCallState.idle;
    _peerId = null;
    _micMuted.value = false;
    _speakerOn.value = true;
  }

  void _armAnswerTimeout() {
    _answerTimer?.cancel();
    _answerTimer = Timer(_answerTimeout, () {
      if (_state.value == WtCallState.calling) {
        _teardown();
        _state.value = WtCallState.failed;
      }
    });
  }

  /// [peerId] may be a concrete member uuid or the server-side alias
  /// "peer" (the sole other member — the only mode the UI enables).
  /// Empty targets are rejected by the server and were the old
  /// broadcast-everyone bug.
  Future<void> start(String peerId) async {
    if (peerId.isEmpty || _state.value != WtCallState.idle) return;
    final client = _client;
    if (client == null || client.state != WtConnectionState.connected) {
      // Dialing on a dead socket guarantees a stuck "calling" state —
      // the offer is silently dropped and no ICE timeout ever fires.
      _state.value = WtCallState.failed;
      return;
    }
    _peerId = peerId;
    _state.value = WtCallState.calling;
    _armAnswerTimeout();
    try {
      await _ensureIceConfig();
      await _createPeer();
      await _getMic();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      if (!_sendSignal({'kind': 'offer', 'sdp': offer.sdp})) {
        throw StateError('offer dropped: socket not open');
      }
    } catch (_) {
      _teardown();
      _state.value = WtCallState.failed;
    }
  }

  static const _fallbackIce = [
    {'urls': 'stun:stun.l.google.com:19302'},
  ];
  List<Map<String, dynamic>>? _iceServers;

  /// Pull TURN/STUN config from the signaling server (it holds the TURN
  /// API secret; clients only ever see short-lived ICE credentials).
  Future<void> _ensureIceConfig() async {
    _iceServers = await _client?.fetchIceServers() ?? _fallbackIce;
  }

  Future<void> _getMic() async {
    _localStream = await fwr.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    for (final track in _localStream!.getTracks()) {
      await _pc?.addTrack(track, _localStream!);
    }
    await fwr.Helper.setSpeakerphoneOn(_speakerOn.value);
    _startVoiceGate();
  }

  /// Poll outbound RTP stats for the mic's audioLevel and gate the track:
  /// below the threshold the track is disabled (nothing is transmitted).
  /// Hysteresis (close at 0.6× the open threshold) avoids flapping on
  /// borderline levels.
  void _startVoiceGate() {
    _gateTimer?.cancel();
    _gateTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      final pc = _pc;
      if (pc == null) return;
      try {
        final stats = await pc.getStats();
        for (final r in stats) {
          final v = r.values;
          final isAudioSource = r.type == 'media-source' ||
              (r.type == 'outbound-rtp' &&
                  (v['kind'] == 'audio' || v['mediaType'] == 'audio'));
          if (!isAudioSource) continue;
          final level = (v['audioLevel'] as num?)?.toDouble();
          if (level == null) continue;
          micLevel.value = level;
          _onMicLevel(level);
          break;
        }
      } catch (_) {}
    });
  }

  void _onMicLevel(double level) {
    final t = gateThreshold.value;
    if (t <= 0) {
      if (!_gateOpen) {
        _gateOpen = true;
        _applyMicEnabled();
      }
      return;
    }
    final open = _gateOpen ? level >= t * 0.6 : level >= t;
    if (open != _gateOpen) {
      _gateOpen = open;
      _applyMicEnabled();
    }
  }

  void _applyMicEnabled() {
    for (final track in _localStream?.getAudioTracks() ?? []) {
      track.enabled = !_micMuted.value && _gateOpen;
    }
  }

  @visibleForTesting
  bool get gateOpenForTesting => _gateOpen;

  @visibleForTesting
  void onMicLevelForTesting(double level) => _onMicLevel(level);

  Future<void> _createPeer() async {
    _hasRemoteDescription = false;
    _pendingCandidates.clear();
    _pc = await fwr.createPeerConnection({
      'iceServers': _iceServers ?? _fallbackIce,
    });
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _answerTimer?.cancel();
        _state.value = WtCallState.connected;
      }
    };
    _pc!.onIceCandidate = (candidate) {
      _sendSignal({
        'kind': 'ice',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    _pc!.onConnectionState = (state) {
      switch (state) {
        case fwr.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case fwr.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // Release the mic immediately on failure; previously the track
          // stayed live until the user manually hung up.
          _teardown();
          _state.value = WtCallState.failed;
        case fwr.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (_state.value == WtCallState.connected) {
            reset();
          }
        default:
          break;
      }
    };
  }

  Future<void> onSignal(WtWebRTCEvent event) {
    _signalWork = _signalWork
        .then((_) => _handleSignal(event))
        .catchError((_) {});
    return _signalWork;
  }

  /// Deterministic glare resolution: both sides compute the same polite
  /// flag from the ordered id pair, so exactly one side rolls back.
  bool get _polite {
    final me = _client?.tempUser ?? '';
    final peer = _peerId ?? '';
    return me.compareTo(peer) > 0;
  }

  /// "peer"/"host" are server-side aliases, not a bound uuid: the first
  /// inbound signal binds us to the real sender.
  bool get _bound =>
      _peerId != null && _peerId != 'peer' && _peerId != 'host';

  Future<void> _handleSignal(WtWebRTCEvent event) async {
    final payload = event.payload;
    final kind = payload['kind'] as String?;

    // Once bound to a peer, drop every signal that is not from it;
    // before binding, only an offer may bind us while idle — mid-call,
    // the responder's first signal binds us to their real uuid.
    if (_bound) {
      if (event.from != _peerId) return;
    } else if (_state.value == WtCallState.idle && kind != 'offer') {
      return;
    } else if (_state.value != WtCallState.idle) {
      _peerId = event.from;
    }

    switch (kind) {
      case 'bye':
        reset();
      case 'offer':
        // SDP/mic failures used to escape _handleSignal and vanish into
        // _signalWork.catchError — leaving the peer ringing forever.
        try {
          if (_state.value == WtCallState.idle) {
            _peerId = event.from;
            _state.value = WtCallState.calling;
            _armAnswerTimeout();
            await _ensureIceConfig();
            await _createPeer();
            await _getMic();
          } else if (!_polite) {
            // Glare: we are impolite, our offer wins — ignore theirs.
            return;
          } else {
            // Glare: we are polite — roll back our local offer.
            try {
              await _pc!.setLocalDescription(
                fwr.RTCSessionDescription(null, 'rollback'),
              );
            } catch (_) {}
          }
          await _pc!.setRemoteDescription(
            fwr.RTCSessionDescription(payload['sdp'], 'offer'),
          );
          _hasRemoteDescription = true;
          final answer = await _pc!.createAnswer();
          await _pc!.setLocalDescription(answer);
          if (!_sendSignal({'kind': 'answer', 'sdp': answer.sdp})) {
            throw StateError('answer dropped: socket not open');
          }
          await _flushCandidates();
        } catch (_) {
          _teardown();
          _state.value = WtCallState.failed;
        }
      case 'answer':
        if (_pc != null && _state.value == WtCallState.calling) {
          try {
            await _pc!.setRemoteDescription(
              fwr.RTCSessionDescription(payload['sdp'], 'answer'),
            );
            _hasRemoteDescription = true;
            _answerTimer?.cancel();
            await _flushCandidates();
          } catch (_) {
            _teardown();
            _state.value = WtCallState.failed;
          }
        }
      case 'ice':
        if (payload['candidate'] == null) return;
        final candidate = fwr.RTCIceCandidate(
          payload['candidate'],
          payload['sdpMid'],
          payload['sdpMLineIndex'],
        );
        if (_pc == null) return;
        if (_hasRemoteDescription) {
          await _pc!.addCandidate(candidate);
        } else {
          // arrived before the remote description — queue it
          _pendingCandidates.add(candidate);
        }
    }
  }

  Future<void> _flushCandidates() async {
    for (final c in _pendingCandidates) {
      try {
        await _pc?.addCandidate(c);
      } catch (_) {}
    }
    _pendingCandidates.clear();
  }

  Future<void> hangUp() async {
    reset();
  }

  void _teardown() {
    _answerTimer?.cancel();
    _answerTimer = null;
    _gateTimer?.cancel();
    _gateTimer = null;
    _gateOpen = true;
    micLevel.value = 0;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    _pc?.close();
    _pc = null;
    _hasRemoteDescription = false;
    _pendingCandidates.clear();
  }

  void onPeerLeft(String tempUser) {
    if (_state.value == WtCallState.idle) return;
    // Unbound alias ('peer'/'host'): the departing member was the only
    // possible counterpart — its uuid never matched the alias, so the
    // old equality check never fired and the call stayed in "calling".
    if (!_bound || _peerId == tempUser) {
      reset();
    }
  }

  /// Signaling socket dropped: the call's signaling path is dead even if
  /// media still flows — tear down so neither side stays in a mismatched
  /// state, and let the user redial after reconnect.
  void onDisconnected() {
    if (_state.value == WtCallState.idle) return;
    _teardown();
    _state.value = WtCallState.failed;
  }

  /// Test seam: seeds a bound peer + state without touching native RTC.
  @visibleForTesting
  void seedForTesting({required String peerId, required WtCallState state}) {
    _peerId = peerId;
    _state.value = state;
  }

  void toggleMic() {
    _micMuted.value = !_micMuted.value;
    _applyMicEnabled();
  }

  Future<void> toggleSpeaker() async {
    _speakerOn.value = !_speakerOn.value;
    await fwr.Helper.setSpeakerphoneOn(_speakerOn.value);
  }

  /// Returns false when the signal could not be sent (no bound peer or
  /// socket not open) — callers that depend on delivery fail the call.
  bool _sendSignal(Map<String, dynamic> payload) {
    final peer = _peerId;
    if (peer == null || peer.isEmpty) return false;
    return _client?.sendWebRTC(peer, payload) ?? false;
  }
}
