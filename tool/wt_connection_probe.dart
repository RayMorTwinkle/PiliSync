// Pure Dart connection smoke test; needs Go signaling at 127.0.0.1:9901.
// fvm dart run tool/wt_connection_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';

Future<void> main(List<String> args) async {
  final serverBase = args.isNotEmpty
      ? args.first
      : (Platform.environment['WT_SERVER'] ?? '127.0.0.1:9901');
  final host = WtSignalingClient();
  final member = WtSignalingClient();
  final room = 'probe-${DateTime.now().microsecondsSinceEpoch}';
  final created = Completer<void>();
  final joined = Completer<WtJoinedEvent>();
  final hostSub = host.events.listen((event) {
    // New rooms are created by update, not join, in the existing protocol.
    if (event is WtUpdateAckEvent && !created.isCompleted) created.complete();
  });
  final memberSub = member.events.listen((event) {
    stdout.writeln(jsonEncode({'firstReceivedType': event.runtimeType.toString()}));
    if (event is WtJoinedEvent && !joined.isCompleted) joined.complete(event);
  });
  final deadline = Timer(const Duration(seconds: 15), () {
    stderr.writeln('FAIL: connection probe exceeded 15 seconds');
    exit(2);
  });
  try {
    await host.connect(serverBase: serverBase, room: room,
        user: 'probe-host', pass: '');
    host.updatePlayback(WtPlaybackState(lastUpdateClientTime: host.timeSync.now()));
    await created.future;
    stdout.writeln(jsonEncode({'createdRoom': room}));
    await member.connect(serverBase: serverBase, room: room,
        user: 'probe-member', pass: '');
    member.join();
    final response = await joined.future;
    if (response.room.name != room || response.isHost) {
      throw StateError('Unexpected join response');
    }
    stdout.writeln(jsonEncode({
      'result': 'PASS', 'room': response.room.name,
      'isHost': response.isHost, 'members': response.room.memberCount,
    }));
  } catch (error, stack) {
    stderr.writeln('FAIL: $error\n$stack');
    exitCode = 2;
  } finally {
    await hostSub.cancel();
    await memberSub.cancel();
    // The existing client starts time-sync asynchronously; let its initial
    // short loop settle before disposal so this probe cannot leak its timer.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await member.dispose();
    await host.dispose();
    deadline.cancel();
  }
  // This one-shot CLI owns the process; client cleanup alone currently leaves
  // runtime work alive. Do not confuse protocol success with cleanup success.
  await stdout.flush();
  await stderr.flush();
  exit(exitCode);
}
