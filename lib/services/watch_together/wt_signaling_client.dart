import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  int _reconnectAttempt = 0;
  bool _disposed = false;

  String serverBase = '127.0.0.1:9901';
  String? roomName;
  String? password;
  String? tempUser;

  WtTimeSync timeSync = WtTimeSync();

  Stream<WtEvent> get events => _events.stream;
  Stream<WtConnectionState> get connectionState => _connectionState.stream;
  WtConnectionState state = WtConnectionState.disconnected;

  StreamSubscription? _socketSub;

  void _setState(WtConnectionState s) {
    state = s;
    _connectionState.add(s);
  }

  bool _isHost = false;

  Future<void> connect({
    required String serverBase,
    required String room,
    required String user,
    required String pass,
    bool isHost = false,
  }) async {
    this.serverBase = serverBase;
    roomName = room;
    tempUser = user;
    password = pass;
    _isHost = isHost;
    _disposed = false;
    _reconnectAttempt = 0;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_disposed || state == WtConnectionState.connected) return;
    _setState(WtConnectionState.connecting);
    try {
      final socket = await WebSocket.connect(
        'ws://$serverBase/ws',
      ).timeout(const Duration(seconds: 8));
      socket.pingInterval = const Duration(seconds: 30);
      _socket = socket;
      _setState(WtConnectionState.connected);
      _reconnectAttempt = 0;
      _listen(socket);
      await sampleServerTime();
      _sendJoin();
      _startTimeSync();
    } catch (_) {
      _setState(WtConnectionState.disconnected);
      _scheduleReconnect();
    }
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

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null) return;
    final delay = Duration(
      seconds: (1 << _reconnectAttempt.clamp(0, 5)).clamp(1, 30),
    );
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _doConnect();
    });
  }

  void _sendJoin() {
    if (roomName == null || tempUser == null) return;
    if (_isHost) {
      updatePlayback(
        WtPlaybackState(lastUpdateClientTime: timeSync.now()),
      );
      return;
    }
    _sendRaw({
      'type': 'join',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
    });
  }

  void _handleServerMessage(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'ping':
        _sendRaw({'type': 'pong', 't': timeSync.localNow()});
      case 'joined':
        final room = WtRoomSnapshot.fromJson(
          msg['room'] as Map<String, dynamic>,
        );
        timeSync.updateIfNeeded(
          msg['timestamp'] as num,
          msg['timestamp'] as num,
          timeSync.localNow(),
        );
        _events.add(
          WtJoinedEvent(room, msg['isHost'] as bool? ?? false, timeSync.now()),
        );
      case 'update_ack':
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
          ),
        );
      case 'peer_joined':
        _events.add(
          WtPeerEvent(
            true,
            msg['tempUser'] as String? ?? '',
            (msg['memberCount'] as num?)?.toInt() ?? 0,
          ),
        );
      case 'peer_left':
        _events.add(
          WtPeerEvent(
            false,
            msg['tempUser'] as String? ?? '',
            (msg['memberCount'] as num?)?.toInt() ?? 0,
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
      case 'error':
        _events.add(WtErrorEvent(msg['code'] as String? ?? 'unknown'));
      case 'tsync_ack':
        final t = (msg['t'] as num?)?.toDouble() ?? 0;
        timeSync.updateIfNeeded(
          (msg['server'] as num?)?.toDouble() ?? 0,
          t,
          timeSync.localNow(),
        );
    }
  }

  Future<void> _startTimeSync() async {
    for (var i = 0; i < 3; i++) {
      _sendRaw({'type': 'tsync', 't': timeSync.localNow()});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _sendRaw(Map<String, dynamic> msg) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(utf8.encode(jsonEncode(msg)));
  }

  void updatePlayback(WtPlaybackState playback) {
    _sendRaw({
      'type': 'update',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'playback': playback.toJson(),
    });
  }

  void updateMember(bool isLoading) {
    _sendRaw({
      'type': 'update_member',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'isLoading': isLoading,
    });
  }

  void navigate(WtTarget target) {
    _sendRaw({
      'type': 'navigate',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'target': target.toJson(),
    });
  }

  void sendWebRTC(String to, Map<String, dynamic> payload) {
    _sendRaw({
      'type': 'webrtc',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'to': to,
      'payload': payload,
    });
  }

  void sendChat(String text) {
    _sendRaw({
      'type': 'chat',
      'room': roomName,
      'password': password,
      'tempUser': tempUser,
      'text': text,
    });
  }

  Future<void> sampleServerTime() async {
    try {
      final start = timeSync.localNow();
      final request = await _httpClient
          .getUrl(Uri.parse('http://$serverBase/timestamp'))
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
