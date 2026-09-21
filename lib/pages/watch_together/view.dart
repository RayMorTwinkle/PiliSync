import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/services/watch_together/watch_together_service.dart';
import 'package:PiliPlus/services/watch_together/wt_call_manager.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class WatchTogetherPage extends StatefulWidget {
  const WatchTogetherPage({super.key});

  @override
  State<WatchTogetherPage> createState() => _WatchTogetherPageState();
}

class _WatchTogetherPageState extends State<WatchTogetherPage> {
  final service = watchTogetherService;
  late final _serverCtrl = TextEditingController(text: service.serverUrl);
  final _roomCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _serverCtrl.dispose();
    _roomCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    service.serverUrl = _serverCtrl.text.trim();
    await service.createRoom();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _join() async {
    final room = _roomCtrl.text.trim();
    if (room.isEmpty) {
      SmartDialog.showToast('请输入房间号');
      return;
    }
    setState(() => _busy = true);
    service.serverUrl = _serverCtrl.text.trim();
    await service.joinRoom(room: room, password: _passwordCtrl.text.trim());
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _leave() async {
    await service.leave();
    if (mounted) setState(() {});
  }

  void _confirmTransfer() {
    SmartDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('转让房主'),
        content: const Text('将房主身份转让给对方？转让后你将跟随对方播放。'),
        actions: [
          TextButton(
            onPressed: SmartDialog.dismiss,
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              SmartDialog.dismiss();
              // 'peer' resolves server-side to the sole other member —
              // the button is only shown in 2-person rooms.
              service.transferHostTo('peer');
            },
            child: const Text('确认转让'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(title: const Text('一起看')),
      body: Obx(
        () => service.inRoom.value
            ? _buildRoomView(Theme.of(context))
            : _buildLobbyView(),
      ),
    );
  }

  Widget _buildLobbyView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _serverCtrl,
          decoration: const InputDecoration(
            labelText: '信令服务器',
            hintText: 'wss://wt.raymor.top',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('创建房间'),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _roomCtrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: '房间号',
            border: OutlineInputBorder(),
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '房间密码（可选）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _join,
          icon: const Icon(Icons.login),
          label: const Text('加入房间'),
        ),
      ],
    );
  }

  Widget _buildRoomView(ThemeData theme) {
    final room = service.room.value;
    final role = service.role.value;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('房间号'),
                    const SizedBox(width: 12),
                    SelectableText(
                      room?.name ?? '-',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: room?.name ?? ''));
                        SmartDialog.showToast('已复制房间号');
                      },
                      icon: const Icon(Icons.copy, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  switch (role) {
                    WtRole.host => '你是房主，你的播放进度会同步给对方',
                    WtRole.member => '你是成员，自动跟随房主',
                    WtRole.none => '',
                  },
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _statRow(theme, '成员数', '${room?.memberCount ?? 0}'),
                _statRow(
                  theme,
                  '对方缓冲中',
                  (room?.waitForLoadding ?? false) ? '是' : '否',
                ),
                if (room?.playback.target != null)
                  _statRow(
                    theme,
                    '当前视频',
                    room!.playback.target!.describe(),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Obx(
              () => Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('宽松同步模式'),
                    subtitle: const Text('容忍5秒进度差；落后过多的一方不再拖住对方，自行追赶'),
                    value: service.looseSync.value,
                    onChanged: (v) => service.looseSyncEnabled = v,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('房主绝对优先'),
                    subtitle: const Text('成员的缓冲/暂停绝不影响房主播放，成员自行追赶'),
                    value: service.hostPriority.value,
                    onChanged: (v) => service.hostPriorityEnabled = v,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('悬浮控制面板'),
                    subtitle: const Text('离开本页后显示一起看悬浮窗'),
                    value: service.floatingPanel.value,
                    onChanged: (v) => service.floatingPanelEnabled = v,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (role.isHost)
          OutlinedButton.icon(
            onPressed: service.navigateToCurrent,
            icon: const Icon(Icons.sync),
            label: const Text('邀请对方看当前视频'),
          ),
        if (role.isHost &&
            (room?.memberCount ?? 0) == 2)
          OutlinedButton.icon(
            onPressed: _confirmTransfer,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('转让房主'),
          ),
        if (role.isMember)
          OutlinedButton.icon(
            onPressed: service.requestHostTransfer,
            icon: const Icon(Icons.person_add_alt),
            label: const Text('申请成为房主'),
          ),
        const SizedBox(height: 12),
        _voiceButton(),
        const SizedBox(height: 12),
        _debugPanel(theme),
        const SizedBox(height: 24),
        FilledButton.tonal(
          onPressed: _busy ? null : _leave,
          child: const Text('退出房间'),
        ),
      ],
    );
  }

  Widget _debugPanel(ThemeData theme) {
    final call = service.call;
    return Obx(() {
      final open = service.debugOverlay.value;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => service.debugOverlay.value = !open,
                child: Row(
                  children: [
                    const Icon(Icons.bug_report, size: 18),
                    const SizedBox(width: 6),
                    Text('Debug', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
                  ],
                ),
              ),
              if (open) ...[
                const SizedBox(height: 8),
                Text(
                  'role=${service.role.value} conn=${service.connState.value} '
                  'tsOffset=${service.client.timeSync.offset.toStringAsFixed(1)} '
                  'minTrip=${service.client.timeSync.hasValidSample ? service.client.timeSync.minTrip.toStringAsFixed(3) : "-"}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  'call=${call.state} mic=${call.micMuted} '
                  'room=${service.room.value?.name} members=${service.room.value?.memberCount} '
                  'wait=${service.room.value?.waitForLoadding}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  'pos=${(service.player.positionMs / 1000).toStringAsFixed(1)} '
                  'playing=${service.player.isPlaying} buf=${service.player.isBuffering} '
                  'lastSeek=${service.memberLastSeekDebug}',
                  style: theme.textTheme.bodySmall,
                ),
                const Divider(height: 12),
                SizedBox(
                  height: 150,
                  child: ListView.builder(
                    reverse: true,
                    itemCount: service.debugLog.length,
                    itemBuilder: (_, i) {
                      final log =
                          service.debugLog[service.debugLog.length - 1 - i];
                      return Text(
                        '${log.t} ${log.msg}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 10,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }

  Widget _voiceButton() {    final call = service.call;
    return Obx(() {
      final callState = call.state;
      return Column(
        children: [
          if (callState == WtCallState.idle)
            OutlinedButton.icon(
              // Voice calls are 1:1 only: "peer" resolves server-side to
              // the sole other member, so the button requires exactly 2.
              onPressed: service.inRoom.value &&
                      (service.room.value?.memberCount ?? 0) == 2
                  ? () => call.start('peer')
                  : null,
              icon: const Icon(Icons.mic),
              label: Text(
                (service.room.value?.memberCount ?? 0) == 2
                    ? '开启语音通话'
                    : '语音通话（仅限双人房间）',
              ),
            )
          else ...[
            Text(
              switch (callState) {
                WtCallState.calling => '通话中…',
                WtCallState.connected => '已接通',
                WtCallState.failed => '通话失败',
                WtCallState.idle => '',
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  onPressed: call.toggleMic,
                  icon: Icon(call.micMuted ? Icons.mic_off : Icons.mic),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: call.toggleSpeaker,
                  icon: Icon(
                    call.speakerOn ? Icons.volume_up : Icons.volume_down,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: call.hangUp,
                  icon: const Icon(Icons.call_end),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Voice gate: quiet sounds below the threshold are not
            // transmitted. 0 = off. The meter shows live mic level.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text('语音阈值', style: Theme.of(context).textTheme.bodySmall),
                      Expanded(
                        child: Obx(
                          () => Slider(
                            value: call.gateThreshold.value.clamp(0.0, 0.3),
                            max: 0.3,
                            divisions: 30,
                            label: call.gateThreshold.value <= 0
                                ? '关闭'
                                : call.gateThreshold.value
                                    .toStringAsFixed(2),
                            onChanged: (v) => call.gateThresholdValue = v,
                          ),
                        ),
                      ),
                      Obx(
                        () => Text(
                          call.gateThreshold.value <= 0
                              ? '关'
                              : call.gateThreshold.value.toStringAsFixed(2),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                  Obx(
                    () => LinearProgressIndicator(
                      value: call.micLevel.value.clamp(0.0, 1.0),
                      minHeight: 3,
                    ),
                  ),
                  // Remote voice loudness on this device.
                  Row(
                    children: [
                      Text('对方音量', style: Theme.of(context).textTheme.bodySmall),
                      Expanded(
                        child: Obx(
                          () => Slider(
                            value: call.remoteVolume.value.clamp(0.0, 2.0),
                            max: 2.0,
                            divisions: 20,
                            label: '${(call.remoteVolume.value * 100).round()}%',
                            onChanged: (v) => call.remoteVolumeValue = v,
                          ),
                        ),
                      ),
                      Obx(
                        () => Text(
                          '${(call.remoteVolume.value * 100).round()}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    });
  }

  Widget _statRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
