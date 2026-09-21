import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:9901/ws'));
  await channel.ready;
  print('connected');
  channel.stream.listen(
    (data) => print('recv: ${utf8.decode(data as List<int>)}'),
    onDone: () => print('done'),
    onError: (e) => print('err: $e'),
  );
  channel.sink.add(utf8.encode(
    jsonEncode({
      'type': 'update',
      'room': 'probeDart',
      'password': '',
      'tempUser': 'dart',
      'playback': {'playbackRate': 1.0, 'currentTime': 5.0, 'paused': false},
    }),
  ));
  print('sent');
  await Future<void>.delayed(const Duration(seconds: 2));
  await channel.sink.close();
}
