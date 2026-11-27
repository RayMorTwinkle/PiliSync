# PiliSync「一起看」同条件复测

成员领先时，暂停是一种等待策略；房主暂停时，暂停又代表一个确定的观看位置。旧版会混淆这两个意图。另一个问题出现在异步命令之间：播放器已经切换，上一轮协调仍可能继续调速、恢复播放并上报加载。此次只改动成员协调器，并为信令服务新增播放模型解码入口，保留既有房间、通话与第三方接入接口。

| 测量对象 | 备份通过数 | 重构通过数 | 观测出口 |
| --- | ---: | ---: | --- |
| Dart 成员播放轨迹 | 7 / 15 | 15 / 15 | 播放器端口调用顺序、加载回调、seek 静默状态 |
| Go 房间契约 | 8 / 14 | 14 / 14 | 本机回环 WebSocket 返回的快照和等待标记 |

分母是预先写入夹具的用例数。样本专门挑选了边界与相邻对照，没有抽样线上用户。没有测量公网时延、帧级同步精度、原生解码器表现、音质或设备能耗。这两行应当分别解读。[成员基线](artifacts/member/before.jsonl) · [成员重构后](artifacts/member/after.jsonl) · [Go 逐例结果](artifacts/go-room/summary.json)

## 实验条件

- 基线为 `backup1126` 的 `314adb86a46f49ec0340ed2f3d9da62af28dbd67`。Go 修改提交为 `b3abd58d547a8ccf5378473c478c8f4b8f47a4f2`，客户端修改提交为 `d11e7657f60f543c1f02fe001d42a2014dbc0b79`。三个取样点在同一提交链上。
- 成员回放向各自源码的 `WtMemberCoordinator.tick` 注入相同的房间快照、人工时钟和内存播放器。两侧均使用 Flutter 3.47.5 附带的 Dart 3.13.4，包语言版本对齐项目约束。使用 Completer 在命令执行中间切换上下文，断言命令流而非睡眠时长。两份 JSONL 首行记录解释器、夹具及所用生产文件的 SHA-256，末行记录汇总。[夹具](artifacts/member/replay.dart) · [取样脚本](artifacts/member/run.py)
- Go 在同一台 darwin/arm64 机器上使用 Go 1.24.3，分别导出两个提交的信令目录，覆盖同一个测试文件，禁用工作区和依赖网络访问，使用 `-count=1`。专项用例开启 `-race`，本机测试服务器运行现有连接与房间处理逻辑。夹具中仅有合成的房间和参与者名称。[Go 夹具](../../signaling/playback_contract_test.go) · [取样脚本](artifacts/go-room/replay.py)

## 成员端：一条等待规则的有效期

回放让成员位于 20 秒、房主位于 10 秒。这两个数字是输入。宽松模式下，第一轮均向成员发送 `pause`。房主随后停在 10 秒，基线第二轮没有发出命令，成员还在 20 秒；候选版本发出了 `seek:10000`。播放器端口以毫秒计数。

| 场景 | 旧版表现 | 重构后观测 |
| --- | --- | --- |
| 等待中房主暂停、切回严格模式、失去有效对时样本 | 已记住的等待仍会覆盖新的决策 | 分别对齐暂停点、seek 后播放、在禁 seek 条件下按房主播放意图执行 |
| 等待 seek 期间重置会话或更换播放器 | 仍向播放器调速、播放、上报，并启动静默期 | 已经发出的 seek 保留，剩余命令与旧上报均被丢弃 |
| 倍速命令尚未返回时重置会话 | 命令完成后继续播放并上报 | 调速后退出，不发送后续播放命令 |
| 播放器明确拒绝常规 seek | 启动静默，下一轮纠偏被抑制 | 失败不启动静默，下一有效 tick 再试 |
| 同一适配器重建底层播放器 | 新实例被上一实例的节流窗口挡住 | 首轮可立即校准新播放器 |

领先等待仍有滞回：超过 5 秒进入，进入后回到不足 2 秒才退出；两处等号方向都有用例。外部暂停冷却、正常命令顺序、成功 seek 后的稳定期、持续缓冲下失败重试的间隔也有对照。等待前捕获会话代际及播放器身份，在异步边界后校验。已发给设备的命令不支持回滚，保护作用从下一个尚未发出的动作开始。[实现](../../lib/services/watch_together/wt_member_coordinator.dart) · [轨迹明细](artifacts/member/after.jsonl)

## 信令端：省略字段也需要跨语言契约

房间用整份播放快照替换上一次状态。原 Dart 模型把缺失的倍速、暂停标记分别解释为 1 和 true，Go 的结构体零值却得到 0 和 false。后续倍速钳制使旧回包出现 0.1 倍速。新解码入口先初始化模型默认值，再读取显式字段。把规则放在解码处后，既有房间处理程序会在走原流程时自然得到统一的值。[Dart 定义](../../lib/services/watch_together/wt_models.dart) · [Go 解码](../../signaling/playback_wire.go)

| 用例组 | 基线 | 候选 | 要保留的区别 |
| --- | ---: | ---: | --- |
| 播放快照字段 | 3 / 7 | 7 / 7 | 缺省或 null 使用模型默认值，显式 false 保留，显式 0 倍速依旧进入已有下限逻辑 |
| 目标页与缓冲等待 | 5 / 7 | 7 / 7 | 目标对象缺失类型或类型为 null 时默认 video，整体目标为 null、显式空字符串以及不同分 P 有各自结果 |

夹具先送入不同的完整快照，随后再发送稀疏快照，同时检查旧目标和旧时长有没有意外残留。常规 Dart 发送端会显式写出播放字段；这些测试覆盖兼容边界，未统计线上出现频率。两版本原有 Go 套件均以退出码 0 结束。[原始基线回包断言](artifacts/go-room/before-contracts.log) · [候选契约日志](artifacts/go-room/after-contracts.log) · [原套件基线](artifacts/go-room/before-existing.log) · [原套件候选](artifacts/go-room/after-existing.log)

## 完整 Flutter 套件

完整 `flutter test` 在两个独立检出目录中执行。基线通过 **104/104**，候选通过 **105/105**，两次最终运行均为零失败、零跳过。候选多出的测试是此次新增的成员轨迹回归入口，其内部复用上面的 15 条夹具。完整套件的分母因此相差一项，不能与固定题目的通过数混用。[最终汇总](artifacts/flutter-suite/summary.json) · [基线输出](artifacts/flutter-suite/before-tests.log) · [候选输出](artifacts/flutter-suite/after-tests.log)

原 `pubspec.lock` 缺少清单已声明的 `gt3_flutter_plugin 0.1.0`，两个版本运行 `flutter pub get --offline --enforce-lockfile` 都退出 65。两个临时检出随后应用相同的测试锁补丁，只补这一项。其余包的版本和 Git 提交均保留，校正锁在两侧都通过严格解析。哈希、SDK 的 macOS 常规补丁及 material_ui 缓存补丁均已归档；仓库的清单、锁和认证模块保持基线内容。[原锁解析输出](artifacts/flutter-suite/before-original-lock.log) · [测试锁差异](artifacts/flutter-suite/test-lock.patch) · [SDK 准备记录](artifacts/flutter-suite/sdk-setup.log)

每个版本使用自身的 Go 房间处理器临时监听 `127.0.0.1:9901`，因此依赖监听器的测试也有实际运行。首次两端各有一个镜像测试超时，日志中测试计时从秒级跳到分钟级。按相同命令、配置和输入复跑后通过。超时的首次结果随最终结果一同提供；本报告不据此估计耗时或稳定性。[首次汇总](artifacts/flutter-suite/first-attempt.json) · [基线首次日志](artifacts/flutter-suite/before-clock-jump.log) · [候选首次日志](artifacts/flutter-suite/after-clock-jump.log)

## 复现

在含两端提交和本报告的仓库根目录执行。Python 仅用标准库。Go 离线复测需先备好 `go.sum` 锁定的模块缓存；首次可在 `signaling/` 下运行 `go mod download`。

```sh
git worktree add --detach ../PiliSync-baseline 314adb86a46f49ec0340ed2f3d9da62af28dbd67
python3 docs/evals/artifacts/member/run.py ../PiliSync-baseline
# 基线会返回 1，并在最后一行打印实际通过数。记录后继续下一次独立运行。
python3 docs/evals/artifacts/member/run.py .
python3 docs/evals/artifacts/go-room/replay.py --baseline 314adb86a46f49ec0340ed2f3d9da62af28dbd67 --candidate b3abd58d547a8ccf5378473c478c8f4b8f47a4f2 --out /tmp/pilisync-eval-go
python3 docs/evals/artifacts/boundaries/compare.py
```

完整 Flutter 复测使用两个专用检出、Flutter 3.47.5 的独立 SDK 和准备好的 Pub 缓存。缓存需要包含锁定版本及测试锁中补齐的包，SDK 和 material_ui 需先按 macOS 配套脚本应用项目补丁。脚本在结束时恢复原锁，命令和两个检出的运行日志写到指定目录。[环境与复测步骤](artifacts/flutter-suite/README.md) · [补丁脚本](artifacts/flutter-suite/patch_macos.py) · [全套复现脚本](artifacts/flutter-suite/run.py)

```sh
git worktree add --detach ../PiliSync-candidate d11e7657f60f543c1f02fe001d42a2014dbc0b79
python3 docs/evals/artifacts/flutter-suite/run.py --baseline ../PiliSync-baseline --candidate ../PiliSync-candidate --sdk "$FLUTTER_ROOT" --pub-cache "$PUB_CACHE" --out /tmp/pilisync-flutter-suite
```

## 面试讨论

**产品经理。** 可以先问「暂停按钮一致时，为什么用户仍说没同步？」带着面试官看第 10 秒和第 20 秒的例子，区分用户想共同停住的画面与播放器为了等待而暂停。验收条件要同时观测位置与意图，并纳入用户手动暂停的反例。线上影响需要另行测量。

**AI Agent 开发。** 可以把同条件回放交给 Agent，要求先指出哪条指令不该出现。挂起 seek、重置会话、再放行 Future，就能观察一个按顺序写的异步函数如何对错误上下文产生副作用。提交应同时保住正常的「seek → 调速 → 播放」顺序和中断后的短路行为。

**后训练与评测。** 房间快照、事件顺序和初始播放器状态可以作为输入，端口命令序列、服务端回包可以作为可执行判分目标。正反例成对保留，可揭露「一律禁止 seek」之类对坏例过拟合的修补。公开夹具适合回归和讲解；若用于模型比较，应另准备持出输入，并区分位置错误、陈旧副作用及协议默认值错误。此次没有训练模型，也没有模型能力提升数据。

## SKIPPED_BLACKBOX

| 保留对象 | 本次边界 |
| --- | --- |
| 上游客户端协议与数据模型 | `lib/http/**`、`lib/grpc/**`、`lib/tcp/**`、`lib/models/**`、`lib/models_new/**` 及调用页面原样保留 |
| 登录、签名、账号、验证码与第三方接口 | `lib/utils/**`、`lib/pages/login*/**`、`lib/services/account_service.dart`、`lib/scripts/**`、平台目录与依赖锁原样保留 |
| 房间旧文件、私有认证、通话与连接细节 | 既有 `signaling/room.go`、`ws.go`、`turn.go`、`update.go`、`site.go`、`.env.example`、`lib/services/watch_together/wt_signaling_client.dart`、`wt_call_manager.dart` 及 `watch_together_service.dart` 原样保留。新增解码方法经 Go 标准库自动接入 |
| 遥测、日志、调试与探针 | `signaling/telemetry.go`、`lib/services/telemetry/**`、`logger.dart`、`wt_debug_server.dart`、`lib/pages/log_table/**`、`tool/**`、既有探针及其测试原样保留。公开实验只用本次生成的合成日志 |
| 外部边界 | ServerX 的部署端口与路径只读核对，宿主回环 3202、容器 9901 及公开前缀 `/pilisync` 保留。MiMo 使用预置脚本，无凭据或参考声源进入仓库。RayHome 只交付独立案例及元数据 |

基线原有文件中，本轮有意改写的只有中文 README 与成员协调器。可用 Git 树的模式和对象 ID 核对其余文件，并检测删除、改名或额外改写。[比较脚本](artifacts/boundaries/compare.py) · [边界核对结果](artifacts/boundaries/result.json)
