import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as fwr;
import 'package:get/get.dart' hide navigator;

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';

enum WtCallState { idle, calling, connected, failed }

class WtCallManager {
  WtCallManager();

  final _state = WtCallState.idle.obs;
  final _micMuted = false.obs;
  final _speakerOn = true.obs;

  fwr.RTCPeerConnection? _pc;
  fwr.MediaStream? _localStream;
  fwr.MediaStream? _remoteStream;
  String? _peerId;
  WtSignalingClient? _client;

  WtCallState get state => _state.value;
  bool get micMuted => _micMuted.value;
  bool get speakerOn => _speakerOn.value;
  fwr.MediaStream? get remoteStream => _remoteStream;

  void attach(WtSignalingClient client) {
    _client = client;
  }

  void reset() {
    _teardown();
    _state.value = WtCallState.idle;
    _peerId = null;
  }

  Future<void> start(String peerId) async {
    if (_state.value != WtCallState.idle) return;
    _peerId = peerId;
    _state.value = WtCallState.calling;
    try {
      await _createPeer();
      _localStream = await fwr.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final track in _localStream!.getTracks()) {
        await _pc?.addTrack(track, _localStream!);
      }
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _sendSignal({
        'kind': 'offer',
        'sdp': offer.sdp,
      });
    } catch (_) {
      _teardown();
      _state.value = WtCallState.failed;
    }
  }

  Future<void> _createPeer() async {
    _pc = await fwr.createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
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

  Future<void> onSignal(WtWebRTCEvent event) async {
    final payload = event.payload;
    if (payload['kind'] == 'bye') {
      reset();
      return;
    }
    if (_state.value == WtCallState.idle &&
        payload['kind'] == 'offer') {
      _peerId = event.from;
      _state.value = WtCallState.calling;
      await _createPeer();
      _localStream = await fwr.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final track in _localStream!.getTracks()) {
        await _pc?.addTrack(track, _localStream!);
      }
      await _pc!.setRemoteDescription(
        fwr.RTCSessionDescription(payload['sdp'], 'offer'),
      );
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _sendSignal({'kind': 'answer', 'sdp': answer.sdp});
      return;
    }
    switch (payload['kind']) {
      case 'answer':
        if (_pc != null) {
          await _pc!.setRemoteDescription(
            fwr.RTCSessionDescription(payload['sdp'], 'answer'),
          );
        }
      case 'ice':
        if (_pc != null && payload['candidate'] != null) {
          await _pc!.addCandidate(
            fwr.RTCIceCandidate(
              payload['candidate'],
              payload['sdpMid'],
              payload['sdpMLineIndex'],
            ),
          );
        }
    }
  }

  Future<void> hangUp() async {
    if (_peerId != null) {
      _sendSignal({'kind': 'bye'});
    }
    reset();
  }

  void _teardown() {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    _pc?.close();
    _pc = null;
  }

  void onPeerLeft(String tempUser) {
    if (_peerId == tempUser) {
      reset();
    }
  }

  void toggleMic() {
    _micMuted.value = !_micMuted.value;
    for (final track in _localStream?.getAudioTracks() ?? []) {
      track.enabled = !_micMuted.value;
    }
  }

  Future<void> toggleSpeaker() async {
    _speakerOn.value = !_speakerOn.value;
    await fwr.Helper.setSpeakerphoneOn(_speakerOn.value);
  }

  void _sendSignal(Map<String, dynamic> payload) {
    _client?.sendWebRTC(_peerId ?? '', payload);
  }
}
