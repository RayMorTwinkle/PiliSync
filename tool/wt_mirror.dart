// Headless member: production signaling + calibration, virtual player only.
// fvm dart run tool/wt_mirror.dart --room=123456 --buffer-seconds=8 --duration=20
// stdout is JSONL. Exit 0: joined and received room state; 2: failure.
// This is a protocol/logic probe, NOT proof of real-device playback recovery.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/watch_together/wt_member_coordinator.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_player_port.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';

void emit(String event, [Map<String, Object?> data = const {}]) {
  stdout.writeln(jsonEncode({
    'ts': DateTime.now().toUtc().toIso8601String(),
    'event': event,
    ...data,
  }));
}

/// No timers or UI. Monotonic elapsed time drives position and scripted loading.
class VirtualPlayer implements WtPlayerAdapter {
  VirtualPlayer({required this.bufferSeconds});
  final double bufferSeconds;
  double elapsed = 0;
  double _positionMs = 0;
  @override
  bool isPlaying = false;
  @override
  double durationMs = 600000;
  @override
  double speed = 1;
  @override
  bool get hasPlayer => true;
  @override
  bool get isLive => false;
  @override
  Object get identity => this;
  @override
  bool get isBuffering => elapsed < bufferSeconds;
  @override
  double get positionMs => _positionMs;

  void advance(double next) {
    // Only time AFTER the buffering deadline can advance media position.
    final start = elapsed > bufferSeconds ? elapsed : bufferSeconds;
    if (isPlaying && next > start) {
      _positionMs += (next - start) * 1000 * speed;
      if (_positionMs > durationMs) _positionMs = durationMs;
    }
    elapsed = next;
  }

  @override
  Future<void> play() async {
    isPlaying = true;
    emit('command', {'command': 'play', 'positionSec': positionMs / 1000});
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    emit('command', {'command': 'pause', 'positionSec': positionMs / 1000});
  }

  @override
  Future<void> seekToMs(double ms) async {
    _positionMs = ms;
    // Seeking must NOT release the independent scripted loading gate.
    emit('command', {'command': 'seek', 'positionSec': ms / 1000});
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
    emit('command', {'command': 'speed', 'speed': value});
  }

  @override
  StreamSubscription<void> onStatusChanged(void Function(bool) cb) =>
      const Stream<void>.empty().listen(null);
}

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  try {
    for (final arg in args) {
      final index = arg.indexOf('=');
      if (!arg.startsWith('--') || index < 3) {
        throw const FormatException('参数格式：--room=123456');
      }
      final key = arg.substring(2, index);
      if (!{'server', 'room', 'buffer-seconds', 'duration'}.contains(key)) {
        throw FormatException('未知参数：$key');
      }
      options[key] = arg.substring(index + 1);
    }
    if (options['room']?.isNotEmpty != true) {
      throw const FormatException('必须指定 --room=房号');
    }
    final buffer = double.parse(options['buffer-seconds'] ?? '8');
    final duration = double.parse(options['duration'] ?? '20');
    if (!buffer.isFinite || !duration.isFinite || buffer < 0 ||
        duration <= buffer || duration > 600) {
      throw const FormatException('要求 0 <= 缓冲秒数 < 运行秒数 <= 600');
    }
    await runMirror(options['server'] ?? '127.0.0.1:9901',
        options['room']!, buffer, duration);
  } catch (error, stack) {
    emit('fatal', {'error': '$error'});
    stderr.writeln(stack);
    exitCode = 2;
  }
  // One-shot CLI owns the process. Flush the timeline before terminating;
  // do not rely on third-party/runtime background handles for process exit.
  await stdout.flush();
  await stderr.flush();
  exit(exitCode);
}

Future<void> runMirror(String server, String room, double buffer,
    double duration) async {
  final client = WtSignalingClient();
  final coordinator = WtMemberCoordinator();
  final player = VirtualPlayer(bufferSeconds: buffer);
  final joined = Completer<void>();
  WtRoomSnapshot? snapshot;
  String? failure;
  var roomUpdates = 0;
  final subscription = client.events.listen((event) {
    emit('received', {'type': event.runtimeType.toString()});
    switch (event) {
      case WtJoinedEvent():
        snapshot = event.room;
        if (!joined.isCompleted) joined.complete();
      case WtRoomUpdateEvent():
        snapshot = event.room;
        roomUpdates++;
      case WtNavigateEvent():
        coordinator.reset();
        emit('navigate', {'target': event.target.toJson()});
      case WtErrorEvent():
        failure = event.code;
        if (!joined.isCompleted) joined.completeError(StateError(event.code));
      default:
        break;
    }
  });
  final watch = Stopwatch();
  try {
    // Install the joined deadline before sending the join request.
    final ready = joined.future.timeout(const Duration(seconds: 10));
    await client.connect(serverBase: server, room: room,
        user: 'mirror-${DateTime.now().microsecondsSinceEpoch}', pass: '');
    client.join();
    await ready;
    emit('joined', {'room': room, 'role': 'member'});
    watch.start();
    var lastReport = -10.0;
    while (watch.elapsedMilliseconds / 1000 < duration) {
      final elapsed = watch.elapsedMilliseconds / 1000;
      if (failure != null) throw StateError(failure!);
      if (client.state != WtConnectionState.connected) {
        throw StateError('镜子连接已断开，测试中止');
      }
      player.advance(elapsed);
      final state = snapshot!;
      if (state.playback.duration > 0) {
        player.durationMs = state.playback.duration * 1000;
      }
      await coordinator.tick(
        room: state.playback,
        waitForLoading: state.waitForLoadding,
        now: client.timeSync.now(),
        player: player,
        reportLoading: (_) {},
        log: (message) => emit('calibrate', {'message': message}),
      );
      if (elapsed - lastReport >= 1) {
        lastReport = elapsed;
        // Renew member status even if loading did not change (server TTL 10s).
        client.updateMember(player.isBuffering);
        emit('state', {
          'elapsed': elapsed,
          'sentLoading': player.isBuffering,
          'positionSec': player.positionMs / 1000,
          'playing': player.isPlaying,
          'roomPaused': state.playback.paused,
          'roomTime': state.playback.currentTime,
          'waitForLoading': state.waitForLoadding,
          'offset': client.timeSync.offset,
          'rtt': client.timeSync.hasValidSample ? client.timeSync.minTrip : null,
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (roomUpdates == 0) throw StateError('未收到房主持续状态，测试无效');
    emit('done', {'roomUpdates': roomUpdates,
      'scope': 'protocol mirror; host pause/resume requires independent evidence'});
  } finally {
    watch.stop();
    await subscription.cancel();
    await client.dispose();
  }
}
