import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/pip_overlay_service.dart';
import 'package:PiliPlus/services/watch_together/watch_together_service.dart';
import 'package:PiliPlus/services/watch_together/wt_call_manager.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Floating "watch together" control panel: stays above every route while
/// in a room so the room page does not have to stay open. Mobile: freely
/// draggable, flings/drops past the left or right edge collapse it into a
/// slim edge tab (tap to restore). Desktop: pinned to the bottom-right
/// corner on top of the app content. Always hidden while the player is
/// fullscreen, while PiP is active, and on the room page itself.
class WtFloatingPanel extends StatefulWidget {
  const WtFloatingPanel({super.key});

  @override
  State<WtFloatingPanel> createState() => _WtFloatingPanelState();
}

class _WtFloatingPanelState extends State<WtFloatingPanel> {
  static const _cardW = 216.0;
  static const _edge = 10.0;

  Offset? _pos; // top-left px; null = default bottom-right
  bool _dockLeft = false;
  bool _dockRight = false;
  String _route = '';
  bool _inPip = false;
  Timer? _routeTimer;

  @override
  void initState() {
    super.initState();
    _route = Get.currentRoute;
    _inPip = PipOverlayService.isInPipMode;
    // GetX keeps no public route stream and isInPipMode is a plain
    // static bool; a light poll covers both — the panel only cares
    // about "am I on the room page / is PiP active".
    _routeTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final r = Get.currentRoute;
      final p = PipOverlayService.isInPipMode;
      if ((r != _route || p != _inPip) && mounted) {
        setState(() {
          _route = r;
          _inPip = p;
        });
      }
    });
  }

  @override
  void dispose() {
    _routeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = watchTogetherService;
    return Obx(() {
      final inRoom = svc.inRoom.value;
      final room = svc.room.value;
      final callState = svc.call.state;
      final micMuted = svc.call.micMuted;
      final speakerOn = svc.call.speakerOn;
      final fullScreen =
          PlPlayerController.instance?.isFullScreen.value ?? false;
      final visible = inRoom &&
          _route != '/watchTogether' &&
          !fullScreen &&
          !_inPip;
      if (!visible) return const SizedBox.shrink();

      final theme = Theme.of(context);
      final card = _card(theme, svc, room?.name ?? '', room?.memberCount ?? 0,
          room?.waitForLoadding ?? false, room?.playback.videoTitle ?? '',
          callState, micMuted, speakerOn);

      // The panel fills the root Stack; size comes from MediaQuery — a
      // LayoutBuilder here would break the Stack→Positioned ParentData
      // chain ("Incorrect use of ParentDataWidget", panel stuck top-left).
      final size = MediaQuery.sizeOf(context);
      final w = size.width, h = size.height;
          if (PlatformUtils.isDesktop) {
            return Positioned(right: _edge, bottom: _edge, child: card);
          }
          final pos = _pos ?? Offset(w - _cardW - _edge, h * 0.6);
          if (_dockLeft || _dockRight) {
            return Positioned(
              left: _dockLeft ? 0 : null,
              right: _dockRight ? 0 : null,
              // the tab is 92px tall; clamp so it never hangs off the
              // bottom edge even if _pos.dy came from a low card drag
              top: pos.dy.clamp(0.0, (h - 96).clamp(0.0, double.infinity)),
              child: _edgeTab(theme, svc,
                  room?.waitForLoadding ?? false, callState),
            );
          }
          return Positioned(
            left: pos.dx,
            top: pos.dy,
            child: GestureDetector(
              onPanUpdate: (d) => setState(() {
                _pos = Offset(
                  (pos.dx + d.delta.dx).clamp(-_cardW * 0.8, w - _cardW * 0.2),
                  (pos.dy + d.delta.dy).clamp(0.0, h - 48),
                );
              }),
              onPanEnd: (_) => setState(() {
                final p = _pos!;
                if (p.dx < -_cardW * 0.35) {
                  _dockLeft = true;
                  // keep the edge-snapped x as the restore position —
                  // storing 0/w would resurrect the card off-screen
                  _pos = Offset(_edge, p.dy);
                } else if (p.dx > w - _cardW * 0.65) {
                  _dockRight = true;
                  _pos = Offset(w - _cardW - _edge, p.dy);
                } else {
                  // snap horizontally to the nearest edge
                  final left = p.dx + _cardW / 2 < w / 2;
                  _pos = Offset(left ? _edge : w - _cardW - _edge, p.dy);
                }
              }),
              child: card,
            ),
          );
    });
  }

  Widget _edgeTab(ThemeData theme, WatchTogetherService svc,
      bool waiting, WtCallState callState) {
    return GestureDetector(
      onTap: () => setState(() {
        _dockLeft = false;
        _dockRight = false;
      }),
      onPanUpdate: (d) => setState(() {
        final h = MediaQuery.of(context).size.height;
        _pos = Offset(
          _pos!.dx,
          (_pos!.dy + d.delta.dy).clamp(0.0, h - 96),
        );
      }),
      child: Material(
        elevation: 6,
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.horizontal(
          left: _dockRight ? const Radius.circular(10) : Radius.zero,
          right: _dockLeft ? const Radius.circular(10) : Radius.zero,
        ),
        child: SizedBox(
          width: 30,
          height: 92,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.groups_2,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(height: 4),
              _dot(waiting, callState),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(bool waiting, WtCallState callState) {
    final color = switch (callState) {
      WtCallState.connected => Colors.green,
      WtCallState.calling => Colors.orange,
      _ => waiting ? Colors.orange : Colors.green,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _card(
    ThemeData theme,
    WatchTogetherService svc,
    String roomName,
    int memberCount,
    bool waiting,
    String videoTitle,
    WtCallState callState,
    bool micMuted,
    bool speakerOn,
  ) {
    final call = svc.call;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: theme.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        width: _cardW,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.groups_2,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '一起看 $roomName',
                      style: theme.textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '$memberCount人',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(width: 6),
                  _dot(waiting, callState),
                ],
              ),
              if (videoTitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  videoTitle,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 2),
              Row(
                children: [
                  if (waiting)
                    Text('等待成员缓冲',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: Colors.orange)),
                  const Spacer(),
                  if (callState == WtCallState.idle ||
                      callState == WtCallState.failed)
                    _miniBtn(
                      theme,
                      icon: Icons.mic,
                      onPressed: memberCount == 2
                          ? () => call.start('peer')
                          : null,
                    )
                  else ...[
                    _miniBtn(
                      theme,
                      icon: micMuted ? Icons.mic_off : Icons.mic,
                      onPressed: call.toggleMic,
                    ),
                    _miniBtn(
                      theme,
                      icon: speakerOn ? Icons.volume_up : Icons.volume_down,
                      onPressed: call.toggleSpeaker,
                    ),
                    _miniBtn(
                      theme,
                      icon: Icons.call_end,
                      color: theme.colorScheme.error,
                      onPressed: call.hangUp,
                    ),
                  ],
                  if (!PlatformUtils.isDesktop)
                    // dock toward whichever edge the card is nearer —
                    // the fling-to-edge gesture is awkward to land on
                    // a 216px card
                    _miniBtn(
                      theme,
                      icon: _nearerLeft(context)
                          ? Icons.chevron_left
                          : Icons.chevron_right,
                      onPressed: () => setState(() {
                        final s = MediaQuery.sizeOf(context);
                        final dy = (_pos ?? Offset(0, s.height * 0.6))
                            .dy
                            .clamp(0.0, s.height - 96);
                        if (_nearerLeft(context)) {
                          _pos = Offset(_edge, dy);
                          _dockLeft = true;
                        } else {
                          _pos = Offset(s.width - _cardW - _edge, dy);
                          _dockRight = true;
                        }
                      }),
                    ),
                  _miniBtn(
                    theme,
                    icon: Icons.open_in_full,
                    onPressed: () => Get.toNamed('/watchTogether'),
                  ),
                  _miniBtn(
                    theme,
                    icon: Icons.logout,
                    onPressed: svc.leave,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _nearerLeft(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final cx = (_pos?.dx ?? (w - _cardW - _edge)) + _cardW / 2;
    return cx < w / 2;
  }

  // No tooltips: the panel lives above the Navigator, where no Overlay
  // ancestor exists — Tooltip would throw "No Overlay widget found".
  Widget _miniBtn(
    ThemeData theme, {
    required IconData icon,
    VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
