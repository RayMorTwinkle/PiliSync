<div align="center">

<img src="assets/images/logo/logo.png" width="84" alt="PiliSync 应用图标">

# PiliSync · 和朋友停在同一帧

一个会「一起看」的 Flutter 客户端。房主打开视频，朋友用房间号加入，跟随进度、暂停与切集，也可以开麦聊天。

[中文交互演示](https://raymortwinkle.github.io/PiliSync/) · [中文短片](docs/media/promo.mp4) · [工程评测](docs/evals/refactor-1126-report.md) · [English guide](README_en.md)

</div>

## 加入一次放映

1. 两人各自进入「我的」页右上角的「一起看」。房主创建房间，把房间号和可选的房间密码发给朋友。
2. 成员加入后，房主按平常方式播放或暂停。房间同步目标和播放意图，两端各自加载自己有权观看的视频。房主切换视频、分 P 或直播页时，成员会跟随导航。
3. 点「语音」发起双人 WebRTC 通话。通话面板可切换静音、扬声器和语音门限。悬浮面板让人离开播放页后仍能操作房间。

网络较慢时，常规模式允许房间为缓冲中的成员等待；「宽松模式」给进度留出更多余量。「房主优先」让成员的状态不再反向暂停房主。断开重连后，客户端会重新读取房间快照。

## 工程现场 · 房主暂停了，成员应该停在哪儿？

假设成员已经看到第 20 秒，房主还在第 10 秒。宽松模式让成员先暂停，保留已经填好的缓冲。此时房主也按下暂停。两个播放器都显示「已暂停」，却展示着不同的画面。旧协调器会继续等待一个已经停住的房主。

现在房主暂停会结束这次等待。成员按快照回到第 10 秒。测试播放器实际记录到的命令由 `[pause]` 变为 `[pause, seek:10000]`，其中进度单位为毫秒。在本地打开 `docs/index.html`，可以换一组进度重演这个决策。[交互页源码](docs/index.html) · [重构前记录](docs/evals/artifacts/member/before.jsonl) · [重构后记录](docs/evals/artifacts/member/after.jsonl)

| 本地复测 | 备份版本 | 重构版本 | 判定依据 |
| --- | ---: | ---: | --- |
| 成员播放协调器 | 7 / 15 | 15 / 15 | 对照播放器命令、加载上报与 seek 后的静默状态 |
| Go 房间快照与缓冲等待 | 8 / 14 | 14 / 14 | 经回环 WebSocket 输入合成消息，读取房间实际回包 |

这些分数统计固定夹具中的通过数。用例专门覆盖边界和反例，不能据此估计用户遇到问题的概率或公网播放延迟。[复测条件、逐项结果和限制](docs/evals/refactor-1126-report.md)

## 从房主的一次暂停读进源码

| 环节 | 应该问的问题 | 源码入口 |
| --- | --- | --- |
| 房主意图 | 缓冲结束后，房主是否还想继续播放？ | [房主播放协调器](lib/services/watch_together/wt_playback_coordinator.dart) |
| 房间快照 | 发送方省略倍速或暂停标记时，两端怎样解释？ | [Go 快照解码](signaling/playback_wire.go) · [Dart 模型](lib/services/watch_together/wt_models.dart) |
| 时间对齐 | 何时外推进度，何时采用房主暂停时的原始位置？ | [时钟采样与播放校准](lib/services/watch_together/wt_sync_logic.dart) |
| 执行命令 | 等待一次 seek 返回期间，房间或播放器换了怎么办？ | [成员协调器](lib/services/watch_together/wt_member_coordinator.dart) · [播放器端口](lib/services/watch_together/wt_player_port.dart) |

房主向 Go 信令服务写入快照。成员根据对时样本、目标视频、播放器状态与房间是否等待，决定本轮的 seek、调速和播放操作。语音通话与视频进度走各自的状态机，房主转让、断线重连、回到目标页均由已有房间服务承接。[客户端房间服务](lib/services/watch_together/watch_together_service.dart) · [既有信令服务说明](signaling/README.md)

## 本地运行与贡献

仅验证上述播放逻辑时，可以直接用 Dart 3.13 或更新版本重放真实协调器，无需房间号、账号或线上服务器。

```sh
python3 docs/evals/artifacts/member/run.py .
(cd signaling && go test -count=1 ./...)
```

在相同的临时测试锁和回环房间服务下，完整 Flutter 套件基线通过 104 项，重构后通过 105 项，均为零跳过。仓库原锁缺少清单已声明的 `gt3_flutter_plugin 0.1.0`，严格离线安装会退出 65。报告保留了原锁错误、临时锁的唯一差异与首次运行超时的日志。[全套测试证据](docs/evals/artifacts/flutter-suite/summary.json) · [复测细节](docs/evals/refactor-1126-report.md#完整-flutter-套件)

编译完整应用前，请按构建指南准备本项目锁定的 Flutter 3.47.5 和所需框架补丁。语音还依赖对应平台的原生 WebRTC 组件及麦克风权限。[版本锁](.fvmrc) · [构建指南](docs/build.md)

```sh
git clone https://github.com/RayMorTwinkle/PiliSync.git
cd PiliSync
flutter pub get
# 按构建指南完成 SDK 和对应依赖的补丁后运行
flutter test
flutter build apk --release --split-per-abi
```

自建房间服务可以在 `signaling/` 运行 `go run .`，默认监听 `:9901`。客户端的「一起看」页支持自定义服务器。现有部署的公开入口为 `wss://api.raymor.top/pilisync`；本地演示页和两组专项评测都能离线读或在回环地址运行。

提交同步问题时，可以给出「房主做了什么 → 成员原先的状态 → 成员应收到的命令」。用虚构的视频标识和相对时间就能描述绝大多数播放问题。欢迎附上一条能同时跑在两个版本上的最小回放。

## 功能与来源

| 来源 | 功能 |
| --- | --- |
| PiliSync | 多人观影房间、同步播放、缓冲互等、房主转让、悬浮面板、双人语音、Go 信令服务、自定义服务器地址 |
| PiliSync 的分发和设置 | 国内更新渠道与 GitHub 更新渠道，可在「其他设置」关闭的遥测 |
| 上游 PiliNara / PiliPlus 系列 | 视频、直播、字幕、弹幕、小窗、动态、离线缓存、合并弹幕、自定义字体、AI 字幕分析与过滤设置 |

<img src="assets/screenshots/510shots_so.png" width="24%" alt="客户端界面预览一"> <img src="assets/screenshots/174shots_so.png" width="24%" alt="客户端界面预览二"> <img src="assets/screenshots/850shots_so.png" width="24%" alt="客户端界面预览三">

界面截图沿用上游素材。历史版本的设置表、完整架构图、操作手册与上游差异分析可在固定版本的说明中查阅。[历史中文手册](https://github.com/RayMorTwinkle/PiliSync/blob/314adb86a46f49ec0340ed2f3d9da62af28dbd67/README.md) · [更新记录](CHANGELOG.md) · [GPL-3.0 许可](LICENSE)

## 🙏 致谢 / Credits

本仓库建立在一长串开源工作之上，致敬每一位上游作者：

- **[bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)** — 直接上游的根基（本项目的大量页面、服务与组件源自它）
- **[Starfallan/PiliNara](https://github.com/Starfallan/PiliNara)** — 本 fork 的直接父仓库
- **[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)** 与 **[guozhigq/pilipala](https://github.com/guozhigq/pilipala)** — 更早的开源血脉
- **[VideoTogether](https://github.com/VideoTogether/VideoTogether)** — 一起看协议语义参考
- **[naaammme/pilipro](https://github.com/naaammme/pilipro)** — 应用内小窗逻辑参考
- **[xmcp/pakku.js](https://github.com/xmcp/pakku.js)** — 合并弹幕算法参考
- **[SocialSisterYi/bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)** — B 站接口文档
- **[media-kit/media-kit](https://github.com/media-kit/media-kit)** · **[dio](https://pub.dev/packages/dio)** · **[flutter_webrtc](https://github.com/flutter-webrtc/flutter-webrtc)** · **[gorilla/websocket](https://github.com/gorilla/websocket)** 等依赖
