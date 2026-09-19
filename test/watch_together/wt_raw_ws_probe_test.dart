import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('raw dart:io websocket reaches server', () async {
    WebSocket ws;
    try {
      ws = await WebSocket.connect(
        'ws://127.0.0.1:9901/ws',
      ).timeout(const Duration(seconds: 2));
    } catch (_) {
      markTestSkipped('signaling server not running on 127.0.0.1:9901');
      return;
    }
    // tsync is a real client->server message; the reply must be tsync_ack,
    // not merely "some bytes" (the old ping assertion passed on errors).
    ws.add(utf8.encode('{"type":"tsync","t":1.0}'));
    final msg = await ws.first.timeout(const Duration(seconds: 2));
    // ignore: avoid_print
    print('RAW_WS recv: $msg');
    await ws.close();
    final decoded = jsonDecode(msg as String) as Map<String, dynamic>;
    expect(decoded['type'], 'tsync_ack');
    expect(decoded['server'], isA<num>());
  });
}
