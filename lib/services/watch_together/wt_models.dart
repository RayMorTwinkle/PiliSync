enum WtRole {
  none,
  host,
  member;

  bool get isHost => this == WtRole.host;
  bool get isMember => this == WtRole.member;
}

class WtTarget {
  final String type;
  final String? bvid;
  final int? cid;
  final int? epid;
  final int? seasonId;
  final int? roomId;
  final String? title;

  const WtTarget({
    required this.type,
    this.bvid,
    this.cid,
    this.epid,
    this.seasonId,
    this.roomId,
    this.title,
  });

  factory WtTarget.fromJson(Map<String, dynamic> json) => WtTarget(
    type: json['type'] as String? ?? 'video',
    bvid: json['bvid'] as String?,
    cid: (json['cid'] as num?)?.toInt(),
    epid: (json['epid'] as num?)?.toInt(),
    seasonId: (json['seasonId'] as num?)?.toInt(),
    roomId: (json['roomId'] as num?)?.toInt(),
    title: json['title'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    if (bvid != null) 'bvid': bvid,
    if (cid != null) 'cid': cid,
    if (epid != null) 'epid': epid,
    if (seasonId != null) 'seasonId': seasonId,
    if (roomId != null) 'roomId': roomId,
    if (title != null) 'title': title,
  };

  bool get isLive => type == 'live';

  String describe() {
    final id = bvid ?? (roomId?.toString()) ?? '?';
    return title == null ? id : '$title ($id)';
  }
}

class WtPlaybackState {
  final double playbackRate;
  final double currentTime;
  final double duration;
  final bool paused;
  final double lastUpdateClientTime;
  final double lastUpdateServerTime;
  final String? url;
  final String? videoTitle;
  final WtTarget? target;

  const WtPlaybackState({
    this.playbackRate = 1.0,
    this.currentTime = 0,
    this.duration = 0,
    this.paused = true,
    this.lastUpdateClientTime = 0,
    this.lastUpdateServerTime = 0,
    this.url,
    this.videoTitle,
    this.target,
  });

  factory WtPlaybackState.fromJson(Map<String, dynamic> json) =>
      WtPlaybackState(
        playbackRate: (json['playbackRate'] as num?)?.toDouble() ?? 1.0,
        currentTime: (json['currentTime'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        paused: json['paused'] as bool? ?? true,
        lastUpdateClientTime:
            (json['lastUpdateClientTime'] as num?)?.toDouble() ?? 0,
        lastUpdateServerTime:
            (json['lastUpdateServerTime'] as num?)?.toDouble() ?? 0,
        url: json['url'] as String?,
        videoTitle: json['videoTitle'] as String?,
        target: json['target'] == null
            ? null
            : WtTarget.fromJson(json['target'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
    'playbackRate': playbackRate,
    'currentTime': currentTime,
    'duration': duration,
    'paused': paused,
    'lastUpdateClientTime': lastUpdateClientTime,
    'lastUpdateServerTime': lastUpdateServerTime,
    if (url != null) 'url': url,
    if (videoTitle != null) 'videoTitle': videoTitle,
    if (target != null) 'target': target!.toJson(),
  };
}

class WtRoomSnapshot {
  final String name;
  // The server never sends the host uuid (it is a write capability);
  // "isHost" is filled per-recipient by the server.
  final bool isHost;
  final bool isProtected;
  final int memberCount;
  final bool waitForLoadding;
  final WtPlaybackState playback;

  const WtRoomSnapshot({
    required this.name,
    required this.isHost,
    required this.isProtected,
    required this.memberCount,
    required this.waitForLoadding,
    required this.playback,
  });

  factory WtRoomSnapshot.fromJson(Map<String, dynamic> json) {
    final playbackJson = <String, dynamic>{...json};
    return WtRoomSnapshot(
      name: json['name'] as String? ?? '',
      isHost: json['isHost'] as bool? ?? false,
      isProtected: json['protected'] as bool? ?? false,
      memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
      waitForLoadding: json['waitForLoadding'] as bool? ?? false,
      playback: WtPlaybackState.fromJson(playbackJson),
    );
  }
}

sealed class WtEvent {
  const WtEvent();
}

class WtJoinedEvent extends WtEvent {
  final WtRoomSnapshot room;
  final bool isHost;
  final double serverTime;
  const WtJoinedEvent(this.room, this.isHost, this.serverTime);
}

class WtUpdateAckEvent extends WtEvent {
  final WtRoomSnapshot room;
  final double serverTime;
  const WtUpdateAckEvent(this.room, this.serverTime);
}

class WtRoomUpdateEvent extends WtEvent {
  final WtRoomSnapshot room;
  final double serverTime;
  const WtRoomUpdateEvent(this.room, this.serverTime);
}

class WtMemberUpdateEvent extends WtEvent {
  final String tempUser;
  final bool isLoading;
  final bool waitForLoadding;
  final int memberCount;
  const WtMemberUpdateEvent(
    this.tempUser,
    this.isLoading,
    this.waitForLoadding,
    this.memberCount,
  );
}

class WtNavigateEvent extends WtEvent {
  final String from;
  final WtTarget target;
  // Server broadcasts the recomputed barrier with the navigate so the
  // room does not sit behind a stale waitForLoadding until the next tick.
  final bool? waitForLoadding;
  const WtNavigateEvent(this.from, this.target, [this.waitForLoadding]);
}

class WtPeerEvent extends WtEvent {
  final bool joined;
  final String tempUser;
  final int memberCount;
  // Present since F11-j: peer join/leave recomputes the barrier server-side
  // (a loading member's departure releases it), so the field propagates the
  // release immediately instead of waiting ~2s for the next update_ack.
  final bool? waitForLoadding;
  const WtPeerEvent(
    this.joined,
    this.tempUser,
    this.memberCount, [
    this.waitForLoadding,
  ]);
}

class WtWebRTCEvent extends WtEvent {
  final String from;
  final Map<String, dynamic> payload;
  const WtWebRTCEvent(this.from, this.payload);
}

class WtChatEvent extends WtEvent {
  final String from;
  final String text;
  final double ts;
  const WtChatEvent(this.from, this.text, this.ts);
}

class WtErrorEvent extends WtEvent {
  final String code;
  const WtErrorEvent(this.code);
}

enum WtConnectionState { disconnected, connecting, connected, failed }

class WtSyncAction {
  final double? seekTo;
  final bool? play;
  final double? playbackRate;

  const WtSyncAction({this.seekTo, this.play, this.playbackRate});

  bool get isEmpty => seekTo == null && play == null && playbackRate == null;

  @override
  String toString() =>
      'WtSyncAction(seekTo: $seekTo, play: $play, rate: $playbackRate)';
}
