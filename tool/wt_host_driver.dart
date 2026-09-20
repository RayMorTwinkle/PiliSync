// Headless HOST driver for watch-together field tests.
// Connects to a signaling server, creates a room, navigates to a target,
// then loops real playback updates so a real app instance can join as
// member and be observed end-to-end.
//
// fvm dart run tool/wt_host_driver.dart \
//   --server=wss://wt.raymor.top --room=123456 \
//   --bvid=BV1GJ411x7h7 --cid=137649199 --title="Never Gonna Give You Up" \
//   --play-after=5 --duration=120
//
// stdout is JSONL.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';

void emit(String event, [Map<String, Object?> data = const {}]) {
  stdout.writeln(jsonEncode({'event': event, ...data}));
}

Future<void> main(List<String> args) async {
  final opt = <String, String>{};
  for (final a in args) {
    final i = a.indexOf('=');
    if (!a.startsWith('--') || i < 3) {
      stderr.writeln('bad arg: $a');
      exit(2);
    }
    opt[a.substring(2, i)] = a.substring(i + 1);
  }
  final room = opt['room'] ??
      (100000 + (DateTime.now().microsecondsSinceEpoch % 900000)).toString();
  final server = opt['server'] ?? 'wss://wt.raymor.top';
  final playAfter = double.tryParse(opt['play-after'] ?? '5') ?? 5;
  final duration = double.tryParse(opt['duration'] ?? '120') ?? 120;
  final target = opt['bvid'] != null
      ? WtTarget(
          type: 'video',
          bvid: opt['bvid'],
          cid: int.tryParse(opt['cid'] ?? ''),
          title: opt['title'],
        )
      : null;

  final client = WtSignalingClient();
  var exitCode = 0;
  final sub = client.events.listen((e) {
    emit('received', {'type': e.runtimeType.toString()});
    if (e is WtErrorEvent) emit('error', {'code': e.code});
    if (e is WtPeerEvent) {
      emit('peer', {'joined': e.joined, 'count': e.memberCount});
    }
    if (e is WtMemberUpdateEvent) {
      emit('member', {
        'loading': e.isLoading,
        'wait': e.waitForLoadding,
        'count': e.memberCount,
      });
    }
  });

  final watch = Stopwatch()..start();
  try {
    await client.connect(
      serverBase: server,
      room: room,
      user: 'host-driver-${watch.elapsedMilliseconds}',
      pass: '',
    );
    client.join();
    emit('room', {'room': room, 'server': server});

    // Room creation piggybacks on first update.
    client.updatePlayback(
      WtPlaybackState(lastUpdateClientTime: client.timeSync.now()),
    );

    var navigated = false;
    var pos = 0.0;
    while (watch.elapsedMilliseconds / 1000 < duration) {
      final t = watch.elapsedMilliseconds / 1000;
      if (target != null && !navigated && t >= 2) {
        client.navigate(target);
        navigated = true;
        emit('navigate', target.toJson());
      }
      final playing = t >= playAfter;
      if (playing) pos += 0.5;
      client.updatePlayback(WtPlaybackState(
        playbackRate: 1,
        currentTime: pos,
        duration: 212,
        paused: !playing,
        lastUpdateClientTime: client.timeSync.now(),
        url: target?.bvid,
        videoTitle: target?.title,
        target: target,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  } catch (e) {
    emit('fatal', {'error': '$e'});
    exitCode = 2;
  } finally {
    await sub.cancel();
    await client.dispose();
  }
  await stdout.flush();
  await stderr.flush();
  exit(exitCode);
}
