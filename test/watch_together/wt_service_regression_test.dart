import 'dart:io';

import 'package:PiliPlus/services/watch_together/watch_together_service.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:PiliPlus/services/watch_together/wt_signaling_client.dart';
import 'package:PiliPlus/services/watch_together/wt_sync_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'wt_member_coordinator_test.dart' show FakePlayer;

class _FakeSync extends WtTimeSync {
  double t = 1000;
  @override
  double localNow() => t;
}

/// Minimal WebSocket stand-in: only readyState/close matter to the
/// watchdog; everything else falls through noSuchMethod.
class _FakeSocket implements WebSocket {
  @override
  int readyState = WebSocket.open;
  bool closeCalled = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #readyState) return readyState;
    if (invocation.memberName == #close) {
      closeCalled = true;
      return Future<void>.value();
    }
    return null;
  }
}

class RecordingSignaling extends WtSignalingClient {
  final loadingReports = <bool>[];
  final playbackUpdates = <WtPlaybackState>[];
  bool transferRequested = false;
  final transferCalls = <String>[];
  final denyCalls = <String>[];
  @override
  bool updateMember(bool isLoading, {WtTarget? target}) {
    loadingReports.add(isLoading);
    return true;
  }
  @override
  bool updatePlayback(WtPlaybackState playback) {
    playbackUpdates.add(playback);
    return true;
  }
  @override
  bool requestHostTransfer() {
    transferRequested = true;
    return true;
  }
  @override
  bool transferHost(String to) {
    transferCalls.add(to);
    return true;
  }
  @override
  bool denyTransfer(String to) {
    denyCalls.add(to);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('authoritative ack releases barrier after loading member leaves', () async {
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    service.role.value = WtRole.host;
    service.inRoom.value = true;
    service.handleEventForTesting(const WtMemberUpdateEvent('member', true, true, 2));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isFalse);
    service.handleEventForTesting(const WtUpdateAckEvent(
      WtRoomSnapshot(name: 'test', isHost: true, isProtected: false,
        memberCount: 1, waitForLoadding: false,
        playback: WtPlaybackState(paused: false, currentTime: 308)), 100,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isTrue);
    expect(player.commands, ['pause', 'play']);
    service.handleEventForTesting(WtUpdateAckEvent(service.room.value!, 101));
    await Future<void>.delayed(Duration.zero);
    expect(player.commands, ['pause', 'play']);
  });

  test('barrier release snapshot respects explicit host pause', () async {
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    service.role.value = WtRole.host;
    service.inRoom.value = true;
    service.handleEventForTesting(const WtMemberUpdateEvent('member', true, true, 2));
    await Future<void>.delayed(Duration.zero);
    service.hostIntent.onPlaybackRequest(false);
    service.handleEventForTesting(const WtUpdateAckEvent(
      WtRoomSnapshot(name: 'test', isHost: true, isProtected: false,
        memberCount: 1, waitForLoadding: false,
        playback: WtPlaybackState(paused: true, currentTime: 308)), 100,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isFalse);
    expect(player.commands, ['pause']);
  });

  test('stuck member player releases room barrier after loading cap', () async {
    // Player exists but never finishes loading (dead network / failed
    // source): isBuffering stays true. The member must stop reporting
    // isLoading once the run exceeds the cap, or the host is held paused
    // behind waitForLoadding forever.
    final player = FakePlayer()
      ..isPlaying = true
      ..isBuffering = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player,
      client: client,
      clock: () => now,
    );
    // Strict mode: this test verifies the loading-run cap, not the
    // loose-mode far-behind release (which would suppress earlier).
    service.looseSync.value = false;
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    service.room.value = WtRoomSnapshot(
      name: 'test', isHost: false, isProtected: false, memberCount: 2,
      waitForLoadding: true,
      playback: WtPlaybackState(
        paused: false, currentTime: 10, duration: 120,
        lastUpdateClientTime: now,
      ),
    );

    // F11-b dwell: the first tick only STARTS the sustained-buffering
    // window — a transient underrun must not pause the whole room.
    await service.tickForTesting();
    expect(client.loadingReports.last, isFalse);

    // Dwell elapsed (>1.5s of continuous buffering): reports loading.
    now += 3;
    await service.tickForTesting();
    expect(client.loadingReports.last, isTrue);

    // Still within the cap: keeps reporting loading.
    now += 10;
    await service.tickForTesting();
    expect(client.loadingReports.last, isTrue);

    // Past the 20s cap (heartbeat needs >=2s between reports).
    now += 12; // total ~22s of reported loading
    await service.tickForTesting();
    expect(client.loadingReports.last, isFalse,
        reason: 'reports=${client.loadingReports}');

    // Buffering clears then restarts: a fresh run gets a fresh window —
    // but only after the dwell confirms it again.
    player.isBuffering = false;
    now += 3;
    await service.tickForTesting();
    player.isBuffering = true;
    now += 3;
    await service.tickForTesting();
    expect(client.loadingReports.last, isFalse,
        reason: 'reports=${client.loadingReports}');
    now += 3;
    await service.tickForTesting();
    expect(client.loadingReports.last, isTrue,
        reason: 'reports=${client.loadingReports}');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('service resumes member after paused seek and does not freeze at target', () async {
    final player = FakePlayer();
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player,
      client: client,
      clock: () => now,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    void room(bool paused) {
      service.room.value = WtRoomSnapshot(
        name: 'test', isHost: false, isProtected: false, memberCount: 2,
        waitForLoadding: false,
        playback: WtPlaybackState(
          paused: paused, currentTime: 10, duration: 120,
          lastUpdateClientTime: now,
        ),
      );
    }
    room(true);
    await service.tickForTesting();
    expect(player.positionMs, 10000);
    for (var i = 0; i < 3; i++) {
      now += 1;
      room(false);
      await service.tickForTesting();
      player.advance(0.25);
    }
    expect(player.positionMs, greaterThan(10000), reason:
      'commands=${player.commands}; loading=${client.loadingReports}; '
      'logs=${service.debugLog.map((entry) => entry.msg).toList()}');
    expect(player.commands, contains('play'));
    expect(client.loadingReports, isNot(contains(true)));
    now += 1;
    room(true);
    await service.tickForTesting();
    expect(player.isPlaying, isFalse);
    expect(player.commands.last, 'pause');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('sync-seek silence suppresses the buffering flush report (F12-b)', () async {
    // A calibrate-issued seek flushes the member's buffer → isBuffering
    // flips true. Without the 2s post-seek silence window the service
    // would report loading → pause the whole room for a self-inflicted
    // flush. The coordinator computes the silenced raw signal; the
    // service must USE it (previously the parameter was dropped).
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => now,
    );
    // Strict mode: the frozen snapshot's extrapolated room time drifts
    // past the 5s far-behind window in loose mode and would mute the
    // report this test is verifying.
    service.looseSync.value = false;
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    service.room.value = WtRoomSnapshot(
      name: 'test', isHost: false, isProtected: false, memberCount: 2,
      waitForLoadding: false,
      playback: WtPlaybackState(
        paused: false, currentTime: 10, duration: 120,
        lastUpdateClientTime: now,
      ),
    );

    // Member sits at 0 while the room plays at 10 → realign seek.
    await service.tickForTesting();
    expect(player.commands.any((c) => c.startsWith('seek')), isTrue,
        reason: 'commands=${player.commands}');
    player.isBuffering = true; // the seek flushed the buffer

    // 3.5s later: past the 1.5s dwell (a naive dwell-only impl would
    // report) but the dwell clock itself restarts after silence ends —
    // no true report yet.
    now = 103.5;
    await service.tickForTesting();
    expect(client.loadingReports, isNot(contains(true)),
        reason: 'reports=${client.loadingReports}');

    // Silence ended ~102s; dwell (1.5s) completes → reports loading.
    now = 105.5;
    await service.tickForTesting();
    expect(client.loadingReports.last, isTrue,
        reason: 'reports=${client.loadingReports}');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('terminal errors leave the room instead of retry-looping (F12-c)', () async {
    final player = FakePlayer();
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;

    for (final code in const [
      'room_full', 'not_in_room', 'already_bound', 'identity_in_use',
    ]) {
      service.inRoom.value = true;
      service.handleEventForTesting(WtErrorEvent(code));
      // leave() is async — drain the microtask chain before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.inRoom.value, isFalse, reason: 'code=$code');
    }

    // Non-terminal errors keep the membership.
    service.inRoom.value = true;
    service.handleEventForTesting(const WtErrorEvent('peer_not_found'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.inRoom.value, isTrue);
  });

  test('member calibration freezes until a fresh snapshot lands (F12-d)', () async {
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => now,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    service.room.value = WtRoomSnapshot(
      name: 'test', isHost: false, isProtected: false, memberCount: 2,
      waitForLoadding: false,
      playback: WtPlaybackState(
        paused: false, currentTime: 50, duration: 120,
        lastUpdateClientTime: now,
      ),
    );

    // Simulated reconnect: connected socket but no fresh snapshot yet —
    // the pre-disconnect room state is stale, do not seek on it.
    service.awaitingFreshSnapshot = true;
    await service.tickForTesting();
    expect(player.commands.where((c) => c.startsWith('seek')), isEmpty,
        reason: 'commands=${player.commands}');

    // Authoritative joined event → gate clears → calibration resumes.
    service.handleEventForTesting(WtJoinedEvent(
      WtRoomSnapshot(
        name: 'test', isHost: false, isProtected: false, memberCount: 2,
        waitForLoadding: false,
        playback: WtPlaybackState(
          paused: false, currentTime: 50, duration: 120,
          lastUpdateClientTime: now,
        ),
      ),
      false, now,
    ));
    now += 2;
    await service.tickForTesting();
    expect(player.commands.where((c) => c.startsWith('seek')), isNotEmpty,
        reason: 'commands=${player.commands}');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('member external pause earns auto-play cooldown (F12-m)', () async {
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => now,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    void roomPlaying() {
      service.room.value = WtRoomSnapshot(
        name: 'test', isHost: false, isProtected: false, memberCount: 2,
        waitForLoadding: false,
        playback: WtPlaybackState(
          paused: false, currentTime: 10, duration: 120,
          lastUpdateClientTime: now,
        ),
      );
    }
    roomPlaying();
    player.positionMs = 10000;
    await service.tickForTesting(); // binds the playback-request sub

    // User pauses (or an audio interrupt pauses) mid-room-play.
    player.emitPlaybackRequest(playing: false);
    player.isPlaying = false;

    now += 1;
    roomPlaying();
    await service.tickForTesting();
    expect(player.commands, isNot(contains('play')),
        reason: 'commands=${player.commands}');

    // Cooldown (10s) over → auto-play resumes.
    now += 11;
    roomPlaying();
    await service.tickForTesting();
    expect(player.commands, contains('play'));
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('host buffering dwell starts at the rising edge (F12-a)', () async {
    // _hostBufferingSince seeded inside the delayed callback was dead
    // code: the fast edge path could never trigger and the stall only
    // surfaced ~3s later via the tick. Seed at the edge → broadcast at
    // edge+dwell.
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    client.timeSync.updateIfNeeded(1000, 1, 1); // sample → _hostUpdate allowed
    service.role.value = WtRole.host;
    service.inRoom.value = true;
    service.room.value = WtRoomSnapshot(
      name: 'test', isHost: true, isProtected: false, memberCount: 2,
      waitForLoadding: false,
      playback: WtPlaybackState(
        paused: false, currentTime: 10, duration: 120,
        lastUpdateClientTime: 100,
      ),
    );
    await service.tickForTesting(); // binds the buffering sub
    final before = client.playbackUpdates.length; // the tick itself updates

    player.setBuffering(true);
    // Rising edge arms the dwell timer — no instant broadcast.
    expect(client.playbackUpdates, hasLength(before));

    // ~1s dwell elapses (real timer) → the stall broadcasts paused=true.
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(client.playbackUpdates, hasLength(greaterThan(before)));
    expect(client.playbackUpdates.last.paused, isTrue,
        reason: 'updates=${client.playbackUpdates}');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('member requestHostTransfer and host transferHostTo send frames', () async {
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: FakePlayer(), client: client, clock: () => 100,
    );
    service.inRoom.value = true;

    service.role.value = WtRole.member;
    service.requestHostTransfer();
    expect(client.transferRequested, isTrue);

    service.role.value = WtRole.host;
    service.transferHostTo('peer');
    expect(client.transferCalls, ['peer']);
  });

  test('host_changed snapshot promotes member and clears member residue', () async {
    // After a transfer the promoted side must drop member-side state
    // (pause cooldown would otherwise suppress its first host update).
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    // Arm the external-pause cooldown, then get promoted.
    player.emitPlaybackRequest(playing: false);
    service.handleEventForTesting(const WtRoomUpdateEvent(
      WtRoomSnapshot(name: 'test', isHost: true, isProtected: false,
        memberCount: 2, waitForLoadding: false,
        playback: WtPlaybackState(paused: false, currentTime: 10)),
      100,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(service.role.value, WtRole.host);
    // Demote again: member calibrate must NOT still be in the old
    // cooldown — the promotion cleared it.
    service.handleEventForTesting(const WtRoomUpdateEvent(
      WtRoomSnapshot(name: 'test', isHost: false, isProtected: false,
        memberCount: 2, waitForLoadding: false,
        playback: WtPlaybackState(paused: false, currentTime: 10)),
      100,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(service.role.value, WtRole.member);
  });
  test('host-priority mode: member loading never pauses the host', () async {
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => 100,
    );
    service.role.value = WtRole.host;
    service.inRoom.value = true;
    service.hostPriorityEnabled = true;
    service.handleEventForTesting(
        const WtMemberUpdateEvent('member', true, true, 2));
    await Future<void>.delayed(Duration.zero);
    // Absolute priority: the member's loading must not touch the host.
    expect(player.isPlaying, isTrue);
    expect(player.commands, isEmpty);

    // Turn it off and the same event applies the barrier as usual.
    service.hostPriorityEnabled = false;
    service.handleEventForTesting(
        const WtMemberUpdateEvent('member', true, true, 2));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isFalse);
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('member re-follows room target when navigate broadcast was missed',
      () async {
    // A member whose socket was dead when the host's navigate(B) went out
    // never saw the event and stayed on video A forever — calibration was
    // skipped off-target but nothing re-armed the follow. The snapshot's
    // target is authoritative: drift must re-navigate.
    final player = FakePlayer()..isPlaying = true;
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => now,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    final navs = <String>[];
    service.navigateHook = (t, _) => navs.add(t.bvid ?? 'live:${t.roomId}');

    // Member followed to video A via the joined snapshot.
    service.handleEventForTesting(WtJoinedEvent(
      WtRoomSnapshot(
        name: 'test', isHost: false, isProtected: false, memberCount: 2,
        waitForLoadding: false,
        playback: WtPlaybackState(
          paused: false, currentTime: 10, duration: 120,
          lastUpdateClientTime: now,
          target: const WtTarget(type: 'video', bvid: 'BV_A', cid: 1),
        ),
      ),
      false, now,
    ));
    expect(service.currentTargetForTesting?.bvid, 'BV_A');
    expect(navs, ['BV_A']);

    // Host switched to B while our socket was dead — only the room
    // snapshot reflects it. The next tick must re-arm the follow.
    service.room.value = WtRoomSnapshot(
      name: 'test', isHost: false, isProtected: false, memberCount: 2,
      waitForLoadding: false,
      playback: WtPlaybackState(
        paused: false, currentTime: 0, duration: 120,
        lastUpdateClientTime: now,
        target: const WtTarget(type: 'video', bvid: 'BV_B', cid: 2),
      ),
    );
    await service.tickForTesting();
    expect(navs, ['BV_A', 'BV_B']);
    expect(service.currentTargetForTesting?.bvid, 'BV_B');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('targetless room snapshot clears member stale target', () async {
    // The host left the video page while the member's socket was dead —
    // the null-navigate frame was missed. The tick's exit guard used to
    // also require a locally-detected target, so a member stuck on a
    // video route the route reader could not see stayed "in the video"
    // forever.
    final player = FakePlayer();
    final client = RecordingSignaling();
    addTearDown(client.dispose);
    var now = 100.0;
    final service = WatchTogetherService.forTesting(
      player: player, client: client, clock: () => now,
    );
    service.role.value = WtRole.member;
    service.inRoom.value = true;
    service.navigateHook = (_, _) {};

    service.handleEventForTesting(WtJoinedEvent(
      WtRoomSnapshot(
        name: 'test', isHost: false, isProtected: false, memberCount: 2,
        waitForLoadding: false,
        playback: WtPlaybackState(
          paused: false, currentTime: 10, duration: 120,
          lastUpdateClientTime: now,
          target: const WtTarget(type: 'video', bvid: 'BV_A', cid: 1),
        ),
      ),
      false, now,
    ));
    expect(service.currentTargetForTesting, isNotNull);

    // Room went targetless (host quit the page). In the test env
    // Get.currentRoute is not a watch route, so _exitVideoTarget clears
    // the marker — the member is no longer "in a video".
    service.room.value = WtRoomSnapshot(
      name: 'test', isHost: false, isProtected: false, memberCount: 2,
      waitForLoadding: false,
      playback: WtPlaybackState(paused: true, lastUpdateClientTime: now),
    );
    await service.tickForTesting();
    expect(service.currentTargetForTesting, isNull);
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('inbound watchdog recovers a half-open socket', () {
    // A NAT/network handover leaves the socket reporting open forever —
    // readyState lies. In-room traffic (heartbeat echo ~2s, server ping
    // 54s) never goes silent this long: >12s inbound silence means dead.
    final client = WtSignalingClient();
    addTearDown(client.dispose);
    final sync = _FakeSync();
    client.timeSync = sync;
    client.roomName = '123456';
    client.tempUser = 'u1';
    client.password = 'pw';
    final socket = _FakeSocket();
    client.socketForTesting = socket;
    client.state = WtConnectionState.connected;
    client.lastInboundAtForTesting = sync.t;

    // Fresh inbound traffic: the socket stays.
    client.ensureAlive();
    expect(socket.closeCalled, isFalse);
    expect(client.state, WtConnectionState.connected);

    // 20s of silence on an "open" socket: kill + schedule reconnect.
    sync.t += 20;
    client.ensureAlive();
    expect(socket.closeCalled, isTrue);
    expect(client.state, WtConnectionState.disconnected);
  });
}
