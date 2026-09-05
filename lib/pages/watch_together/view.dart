import 'package:PiliPlus/services/watch_together/watch_together_service.dart';
import 'package:PiliPlus/services/watch_together/wt_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('一起看')),
      body: Obx(
        () => service.inRoom.value
            ? _buildRoomView(context, theme)
            : _buildLobbyView(theme),
      ),
    );
  }

  Widget _buildLobbyView(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _serverCtrl,
          decoration: const InputDecoration(
            labelText: '信令服务器',
            hintText: '127.0.0.1:9901',
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

  Widget _buildRoomView(BuildContext context, ThemeData theme) {
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
                    Text(
                      '房间号',
                      style: theme.textTheme.bodyMedium,
                    ),
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
                        Clipboard.setData(
                          ClipboardData(text: room?.name ?? ''),
                        );
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
                  _statRow(theme, '当前视频', room!.playback.target!.describe()),
              ],
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
        const SizedBox(height: 24),
        FilledButton.tonal(
          onPressed: () async {
            await service.leave();
            if (mounted) setState(() {});
          },
          child: const Text('退出房间'),
        ),
      ],
    );
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
