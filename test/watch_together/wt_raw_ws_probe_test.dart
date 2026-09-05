import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('raw dart:io websocket reaches server', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:9901/ws');
    ws.add(utf8.encode('{"type":"ping","t":1}'));
    final msg = await ws.first.timeout(const Duration(seconds: 2));
    // ignore: avoid_print
    print('RAW_WS recv: $msg');
    await ws.close();
    expect(msg, isNotNull);
  });
}
