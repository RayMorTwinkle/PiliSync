import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';

class WtSignalingClient {
  WtSignalingClient({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  final _events = StreamController<WtEvent>.broadcast();
  final _connectionState = StreamController<WtConnectionState>.broadcast();

  WebSocket? _socket;
  Timer? _reconnectTimer;
  Timer? _tsyncTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;

  String serverBase = 'wt.raymor.top';
  bool _secure = true;
  String? roomName;
  String? password;
  String? tempUser;

  WtTimeSync timeSync = WtTimeSync();

  Stream<WtEvent> get events => _events.stream;
  Stream<WtConnectionState> get connectionState => _connectionState.stream;
  WtConnectionState state = WtConnectionState.disconnected;

  /// Whether the socket is currently usable (a "connected" state with a
  /// dead socket is a fake-alive, e.g. after suspend/resume).
  bool get isOpen => _socket?.readyState == WebSocket.open;

  StreamSubscription? _socketSub;

  void _setState(WtConnectionState s) {
    state = s;
    _connectionState.add(s);
  }

  /// Connects the socket only; joining the room is a separate [join] call
  /// so the caller can subscribe to [events] before `joined` can arrive.
  Future<void> connect({
    required String serverBase,
    required String room,
    required String user,
    required String pass,
  }) async {
    final parsed = _normalizeBase(serverBase);
    this.serverBase = parsed.base;
    _secure = parsed.secure;
    roomName = room;
    tempUser = user;
    password = pass;
    _disposed = false;
    _reconnectAttempt = 0;
    await _openSocket(autoJoin: false);
  }

  /// Sends join for the configured room. Call after subscribing to
  /// [events]; reconnects re-join automatically.
  void join() => _sendJoin();

  static ({String base, bool secure}) _normalizeBase(String input) {
    var s = input.trim();
    var secure = false;
    final lower = s.toLowerCase();
    for (final scheme in ['wss://', 'https://']) {
      if (lower.startsWith(scheme)) {
        secure = true;
        s = s.substring(scheme.length);
        break;
      }
    }
    if (!secure) {
      for (final scheme in ['ws://', 'http://']) {
        if (lower.startsWith(scheme)) {
          s = s.substring(scheme.length);
          break;
        }
      }
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return (base: s, secure: secure);
  }

  Future<void> _openSocket({bool autoJoin = true}) async {
    if (_disposed) return;
    _setState(WtConnectionState.connecting);
    WebSocket socket;
    try {
      socket = await WebSocket.connect(
        '${_secure ? 'wss' : 'ws'}://$serverBase/ws',
      ).timeout(const Duration(seconds: 8));
    } catch (e) {
      _setState(WtConnectionState.disconnected);
      rethrow;
    }
    if (_disposed) {
      await socket.close();
      return;
    }
    socket.pingInterval = const Duration(seconds: 30);
    _socket = socket;
    _setState(WtConnectionState.connected);
    _reconnectAttempt = 0;
    _listen(socket);
    unawaited(sampleServerTime());
    if (autoJoin) _sendJoin();
    _startTimeSync();
  }

  void _listen(WebSocket socket) {
    _socketSub?.cancel();
    _socketSub = socket.listen(
      (data) {
        try {
          final text = data is String ? data : utf8.decode(data as List<int>);
          final msg = jsonDecode(text) as Map<String, dynamic>;
          _handleServerMessage(msg);
        } catch (_) {}
      },
      onDone: _handleDisconnect,
      onError: (_) => _handleDisconnect(),
      cancelOnError: true,
    );
  }

  void _handleDisconnect() {
    if (_disposed) return;
    _socket = null;
    _setState(WtConnectionState.disconnected);
    _scheduleReconnect();
  }

  /// Called periodically by the service: detects fake-alive sockets (state
  /// says connected but the socket is dead) and starts recovery early
  /// instead of waiting for the ping timeout.
  void ensureAlive() {
    if (_disposed || roomName == null) return;
    if (state == WtConnectionState.connected && !isOpen) {
      _handleDisconnect();
    }
  }

  static const _maxReconnectAttempt = 12;

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null) return;
    if (_reconnectAttempt >= _maxReconnectAttempt) {
      // Terminal state: surface it so the UI can close the room instead
      // of sitting in a zombie "in room but dead" state forever.
      _setState(WtConnectionState.failed);
      return;
    }
    final exp = (1 << _reconnectAttempt.clamp(0, 4)).clamp(1, 15);
    // full jitter to avoid synchronized reconnect storms
    final delay = Duration(
      milliseconds: (exp * 1000 * Random().nextDouble()).round() + 500,
    );
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _openSocket().catchError((_) => _handleDisconnect());
    });
  }

  void _sendJoin() {
    if (roomName == null || tempUser == null) return;
    _sendRaw({
      'type': 'join',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
    });
  }

  void _sampleEcho(Map<String, dynamic> msg) {
    final t = (msg['t'] as num?)?.toDouble();
    final server = (msg['timestamp'] as num?)?.toDouble();
    if (t != null && server != null) {
      timeSync.updateIfNeeded(server, t, timeSync.localNow());
    }
  }

  void _handleServerMessage(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'ping':
        _sendRaw({'type': 'pong', 't': timeSync.localNow()});
      case 'tsync_ack':
        final t = (msg['t'] as num?)?.toDouble() ?? 0;
        timeSync.updateIfNeeded(
          (msg['server'] as num?)?.toDouble() ?? 0,
          t,
          timeSync.localNow(),
        );
      case 'joined':
        final room = WtRoomSnapshot.fromJson(
          msg['room'] as Map<String, dynamic>,
        );
        _events.add(
          WtJoinedEvent(room, msg['isHost'] as bool? ?? false, timeSync.now()),
        );
      case 'update_ack':
        _sampleEcho(msg);
        _events.add(
          WtUpdateAckEvent(
            WtRoomSnapshot.fromJson(msg['room'] as Map<String, dynamic>),
            timeSync.now(),
          ),
        );
      case 'room':
        _events.add(
          WtRoomUpdateEvent(
            WtRoomSnapshot.fromJson(msg['room'] as Map<String, dynamic>),
            timeSync.now(),
          ),
        );
      case 'member_update':
        // the server echoes our own update_member back; the `t` echo is a
        // valid time sample only when we were the sender.
        if (msg['tempUser'] == tempUser) {
          _sampleEcho(msg);
        }
        _events.add(
          WtMemberUpdateEvent(
            msg['tempUser'] as String? ?? '',
            msg['isLoading'] as bool? ?? false,
            msg['waitForLoadding'] as bool? ?? false,
            (msg['memberCount'] as num?)?.toInt() ?? 0,
          ),
        );
      case 'navigate':
        _events.add(
          WtNavigateEvent(
            msg['from'] as String? ?? '',
            WtTarget.fromJson(msg['target'] as Map<String, dynamic>),
            msg['waitForLoadding'] as bool?,
          ),
        );
      case 'peer_joined':
        _events.add(
          WtPeerEvent(
            true,
            msg['tempUser'] as String? ?? '',
            (msg['memberCount'] as num?)?.toInt() ?? 0,
            msg['waitForLoadding'] as bool?,
          ),
        );
      case 'peer_left':
        _events.add(
          WtPeerEvent(
            false,
            msg['tempUser'] as String? ?? '',
            (msg['memberCount'] as num?)?.toInt() ?? 0,
            msg['waitForLoadding'] as bool?,
          ),
        );
      case 'webrtc':
        _events.add(
          WtWebRTCEvent(
            msg['from'] as String? ?? '',
            (msg['payload'] as Map<String, dynamic>?) ?? {},
          ),
        );
      case 'chat':
        _events.add(
          WtChatEvent(
            msg['from'] as String? ?? '',
            msg['text'] as String? ?? '',
            (msg['ts'] as num?)?.toDouble() ?? 0,
          ),
        );
      case 'room_closed':
        _events.add(const WtErrorEvent('room_closed'));
      case 'error':
        _events.add(WtErrorEvent(msg['code'] as String? ?? 'unknown'));
    }
  }

  /// Returns false when the message was dropped because the socket is not
  /// open (e.g. mid-reconnect). Callers that care can surface it.
  bool _sendRaw(Map<String, dynamic> msg) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      return false;
    }
    socket.add(utf8.encode(jsonEncode(msg)));
    return true;
  }

  /// Returns false when the socket was not open — the caller can retry on
  /// its next tick instead of silently losing the state.
  bool updatePlayback(WtPlaybackState playback) {
    return _sendRaw({
      'type': 'update',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'playback': playback.toJson(),
      't': timeSync.localNow(),
    });
  }

  bool updateMember(bool isLoading, {WtTarget? target}) {
    return _sendRaw({
      'type': 'update_member',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'isLoading': isLoading,
      if (target != null) 'target': target.toJson(),
      't': timeSync.localNow(),
    });
  }

  bool navigate(WtTarget target) {
    return _sendRaw({
      'type': 'navigate',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'target': target.toJson(),
    });
  }

  bool sendWebRTC(String to, Map<String, dynamic> payload) {
    return _sendRaw({
      'type': 'webrtc',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'to': to,
      'payload': payload,
    });
  }

  // sendChat removed: the chat path is dead code client-side (no UI), the
  // server still relays chat for future use.

  Future<void> _startTimeSync() async {
    _tsyncTimer?.cancel();
    for (var i = 0; i < 3; i++) {
      _sendRaw({'type': 'tsync', 't': timeSync.localNow()});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _tsyncTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _sendRaw({'type': 'tsync', 't': timeSync.localNow()});
    });
  }

  /// Fetches the WebRTC iceServers array from the signaling server. The
  /// server mints short-lived TURN credentials upstream (Cloudflare) so
  /// the TURN API token never ships in the app; falls back to public
  /// STUN when the endpoint is unreachable or unconfigured.
  Future<List<Map<String, dynamic>>> fetchIceServers() async {
    try {
      final request = await _httpClient
          .getUrl(
            Uri.parse(
              '${_secure ? 'https' : 'http'}://$serverBase/ice-servers',
            ),
          )
          .timeout(const Duration(seconds: 5));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final list = json['iceServers'] as List?;
      if (list != null && list.isNotEmpty) {
        return list.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}
    return const [
      {'urls': 'stun:stun.l.google.com:19302'},
    ];
  }

  Future<void> sampleServerTime() async {
    try {
      final start = timeSync.localNow();
      final request = await _httpClient
          .getUrl(
            Uri.parse('${_secure ? 'https' : 'http'}://$serverBase/timestamp'),
          )
          .timeout(const Duration(seconds: 5));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final end = timeSync.localNow();
      final json = jsonDecode(body) as Map<String, dynamic>;
      timeSync.updateIfNeeded(json['timestamp'] as num, start, end);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _tsyncTimer?.cancel();
    _tsyncTimer = null;
    await _socketSub?.cancel();
    _socketSub = null;
    await _socket?.close();
    _socket = null;
    _setState(WtConnectionState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
    await _connectionState.close();
    _httpClient.close();
  }
}
