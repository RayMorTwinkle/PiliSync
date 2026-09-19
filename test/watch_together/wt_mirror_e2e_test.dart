import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:flutter_test/flutter_test.dart';

// Requires the local Go signaling server on :9901, like wt_signaling_e2e_test.
void main() {
  test('standalone mirror receives playback and sends loading true then false', () async {
    try {
      final c = await Socket.connect(
        '127.0.0.1',
        9901,
        timeout: const Duration(milliseconds: 500),
      );
      await c.close();
    } catch (_) {
      markTestSkipped('signaling server not running on 127.0.0.1:9901');
      return;
    }
    final host = WtSignalingClient();
    final room = 'mirror-test-${DateTime.now().microsecondsSinceEpoch}';
    final ack = Completer<void>();
    final loading = <bool>[];
    final sub = host.events.listen((event) {
      if (event is WtUpdateAckEvent && !ack.isCompleted) ack.complete();
      if (event is WtMemberUpdateEvent) loading.add(event.isLoading);
    });
    Process? mirror;
    Timer? updates;
    final lines = <Map<String, dynamic>>[];
    final errors = StringBuffer();
    try {
      await host.connect(serverBase: '127.0.0.1:9901', room: room,
          user: 'host', pass: '');
      void update() => host.updatePlayback(WtPlaybackState(
        paused: false, currentTime: 10, duration: 120,
        lastUpdateClientTime: host.timeSync.now(),
      ));
      update();
      await ack.future.timeout(const Duration(seconds: 5));
      updates = Timer.periodic(const Duration(milliseconds: 200), (_) => update());
      mirror = await Process.start('fvm', [
        'dart', 'run', 'tool/wt_mirror.dart', '--room=$room',
        '--buffer-seconds=1', '--duration=4',
      ]);
      final stdoutDone = mirror.stdout.transform(utf8.decoder)
          .transform(const LineSplitter()).forEach((line) {
        // FVM/Dart build hooks may prepend non-JSON launch diagnostics.
        final start = line.indexOf('{');
        if (start < 0) {
          errors.writeln(line);
          return;
        }
        final event = jsonDecode(line.substring(start)) as Map<String, dynamic>;
        lines.add(event);
        // ignore: avoid_print
        print('MIRROR ${jsonEncode(event)}');
      });
      final stderrDone = mirror.stderr.transform(utf8.decoder).forEach(errors.write);
      final code = await mirror.exitCode.timeout(const Duration(seconds: 40),
        onTimeout: () => throw TimeoutException(
          'mirror did not exit; stderr=$errors; last=${lines.isEmpty ? null : lines.last}; loading=$loading',
        ));
      await Future.wait([stdoutDone, stderrDone]);
      final evidence = 'stderr=$errors\njsonl=$lines\nloading=$loading';
      expect(code, 0, reason: evidence);
      expect(lines.any((line) => line['event'] == 'joined'), isTrue, reason: evidence);
      expect(loading, containsAllInOrder([true, false]), reason: evidence);
      expect(lines.any((line) => line['event'] == 'command' &&
          line['command'] == 'play'), isTrue, reason: evidence);
      final states = lines.where((line) => line['event'] == 'state');
      expect(states.any((line) => line['sentLoading'] == false &&
          (line['positionSec'] as num) > 10), isTrue, reason: evidence);
      expect(lines.last['event'], 'done', reason: evidence);
    } finally {
      updates?.cancel();
      mirror?.kill();
      await sub.cancel();
      await host.dispose();
    }
    // Outer timeout must exceed the inner 40s mirror-exit deadline or the
    // diagnostic timeout exception can never fire.
  }, timeout: const Timeout(Duration(seconds: 60)));
}
