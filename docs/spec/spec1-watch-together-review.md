# spec1 · 一起看（Watch Together）审查问题一次性修复

> 来源：2026-09-19 多 agent 代码审查（Go 服务端 / Dart 客户端 / WebRTC / VT 语义对齐 / 测试卫生），关键论断均已复核。
> **范围**：本文件取代 spec1–spec9 九个文件，作为一次性修复工单。
> **不做**：所有 iOS 平台相关项一律跳过（含 `NSMicrophoneUsageDescription`、iOS 音频会话行为）。
>
> 修复顺序即下列 F1→F9；每项含：问题 → 位置 → 修法 → 验收。

## 구현 상태 (2026-09-19 修复完成)

| 项 | 状态 | 落地 |
|---|---|---|
| F1 身份模型 | ✅ | `room.go` snapshot 无 hostId + per-recipient `isHost`；`ws.go` boundAs/rebindGuard、playback 校验先于夺权；客户端改读 `isHost` |
| F2 心跳/loading | ✅ | 成员=连接存活口径（废弃 LastSeen）；片尾豁免；`target` 聚合（`sameTarget`）；客户端 `_memberHeartbeat` ~2s 心跳（对齐 VT）+ early-return 自动清零 |
| F3 夺权/角色 | ✅ | `members`/`seen` 拆表；join 不登记、首条 update 夺权（VT）；`_applyAuthoritativeRole` 升/降职；`other_host_syncing` 降职+toast 节流 |
| F4 生命周期 | ✅ | `kick()` 排空后关（room_closed 可达）；`Room.id` 实例匹配防误踢；`c.roomName`/`c.tempUser` 统一 `h.mu`；重绑拒绝（无幽灵 member） |
| F5 语音通话 | ✅ | 服务端 `to` 必填+`"host"`/`"peer"` 别名（peer=双人房唯一对方）；UI 仅双人房启用；`event.from` 过滤+串行信令+ICE 队列+polite/impolite glare；failed→teardown；reset 发 bye；断线 teardown；`WtCallManager` 单测 6 件 |
| F6 对时/外推 | ✅ | joined 伪采样删除；`canSeek`（hasValidSample）守卫；`extrapolateCurrent` clamp `[0,duration]`；update/update_member `t` 回显采样；member_update 即时刷新成员侧 barrier；`isSettling` 经 `_lastSeekAt`；`_trips` 删除；host 未对时不广播 |
| F7 重连/导航 | ✅ | `_followNavigate` 同 target 跳过；订阅先行+显式 `join()`；epid/seasonId+`viewPgc` 兜底；房间页不 off；邀请按钮 fallback `_currentTarget`；发送失败重试（navigate 返回 bool）；退避 jitter+上限；`ensureAlive` 假活检测；建房无「已重建」误 toast；`setTargetLocked` 原子重置进度 |
| F8 服务端加固 | ✅ | per-conn 令牌桶（10msg/s, burst 20）；maxClients 5000+per-IP 上限；chat UTF-8 rune 截断；上限检查入 `GetOrCreate` 锁内；重复 join 幂等；未知 member update_member 拒 |
| F9 测试/卫生 | ✅ | e2e socket 探测 `markTestSkipped`；probe 断言 `tsync_ack`；mirror 外层超时 60s；DebugServer 绑 loopback；`wss://`/`https://` scheme 保留；`debugOverlay` RxBool；`sendChat` 死代码移除；README/tool README 补齐；`.gitignore` 加 `.env*`/`*.pem`/`*.key`/secrets 模式 |

**验证结果**：`go test -race ./...` 全绿；`fvm flutter test test/watch_together/` +36 全绿（e2e 无服务器自动 skip）；`dart analyze` 改动文件无 warning/error（info-level 仅既有风格项）。

**已知残留（产品决策/环境依赖，非缺陷）**：TURN 机制已接入（服务端 `GET /ice-servers` 代取 Cloudflare 短期凭据，`TURN_KEY_ID`/`TURN_API_TOKEN` 经 `signaling/.env` 注入，token 不进客户端）；重连 12 次上限后停止自动重试（用户手动重进）；iOS 相关项按约定全部跳过。

---

## F1 · 服务端身份模型：hostId 泄露 + tempUser 冒充（P0）

**问题**：`snapshotLocked` 把 `hostId` 明文广播给全员；`update`/`navigate` 用**消息里的** `msg.TempUser` 判房主 → 任何人读快照拿 hostId 后伪造 update 即夺权。`handleUpdate` 先夺权后校验 playback（无 playback 也能改写 HostId）；`handleNavigate`/`handleWebRTC` 不校验连接绑定。

**位置**：`signaling/room.go:76`；`signaling/ws.go:239,250,265-268,315,334-354`。客户端依赖 `watch_together_service.dart:325`（`hostId == myTempUser` 升职）。

**修法**：
1. 快照不下发原始 `hostId`，改为 per-recipient `isHost`（按接收者 tempUser 填充，同 `joined.isHost` 语义）；
2. `msg.Playback == nil` 校验移到夺权逻辑之前；
3. `handleUpdate`/`handleNavigate`/`handleWebRTC`/`handleUpdateMember` 对已绑定连接强制 `msg.TempUser == c.tempUser` 且 `msg.Room == c.roomName`（夺权只允许未绑定连接以新 tempUser 声明）；
4. 客户端升职逻辑改读 `isHost`。

**验收**：Go 测试断言快照无 `hostId`；成员发 `update{tempUser:房主}` 被拒且 HostId 不变；无 playback 的 update 不改写 HostId；未绑定连接发 navigate/webrtc 被拒；合法重连夺权仍工作；`-race` 全绿。

---

## F2 · 成员心跳与 loading 口径（P0）

**问题**：服务端按 `LastSeen<10s` 判活跃，客户端只在 loading 变化时上报 → 安静成员 10s 后从 memberCount 消失；缓冲 >10s 被提前放行；`_memberTick` early return（无 player/直播）不再上报 false → isLoading 卡死全房间。`memberCount` 快照（len）与广播（activeMembers）两口径矛盾；无片尾豁免（VT `duration!=currentTime`）；`update_member` 无 url 字段，走错页面的成员污染聚合。

**位置**：`room.go:69,77,134-155`；`watch_together_service.dart:282-289,301-307`；`ws.go:121`。

**修法**：
1. 服务端改为**连接存活口径**：memberCount = `len(members)`（断线已 removeMember），loading 语义 = 「上报后直到撤销或断线」，废弃 LastSeen 窗口（`activeMembers`/`anyoneLoading` 不再按时间过滤）；
2. `anyoneLoading` 增加 `duration != currentTime` 片尾豁免；
3. 客户端 `_memberTick` early return 前 `_reportLoading(false)`；重连重置 `_lastReportedLoading` 并立即上报当前态；
4. `update_member` 增加 `target`（type+bvid/epid）字段，服务端聚合时仅计入与房间 target 相同的成员（对齐 VT `IsJoined` 的 CurrentUrl 规则；无 target 的成员不计入 loading 聚合）。

**验收**：Go 测试——成员 >10s 无消息仍计入 memberCount、loading 保持；片尾 loading 不阻塞；client 单测——early return 分支发出 `update_member(false)`、重连后重报；跨 target 成员不计入聚合。

---

## F3 · 夺权语义与角色权威（P0）

**问题**：夺权判定复用 `members`（在线表）：join 先注册 → 已 join 成员永不能夺权；断线即删 → 房主重启换新 uuid 被自己房间锁死 ~3min，且同名双连接可反向抢活跃房主。客户端忽略 `joined.isHost` 权威、无降职路径 → `other_host_syncing` 每 2s toast 刷屏。

**位置**：`ws.go:195,239-248,434`；`room.go:157-162`；`watch_together_service.dart:138,312-328,406-408`；对照 VT `service.go:130-155,204-211`。

**修法**：
1. 服务端拆表：`members`（在线，断线删）+ `seenUsers`（历史，只写不删，随房间过期消失）；`join` 不注册 `seenUsers`，`update` 路径注册；夺权判定查 `seenUsers`；
2. 客户端 `WtJoinedEvent`：`role = isHost ? host : member` 并 `_startLoop()` 校正；`other_host_syncing` 与快照 `isHost==false` 时降职 member（停止 host loop）。

**验收**：Go 测试——join 后发 update 夺权成功（VT 语义）；同名双连接 conn1 断开后 conn2 update 不夺权；房主断线→新 tempUser join+update 夺回成功；Dart 单测——`isHost:false` 注入降职停 loop；`other_host_syncing` 后无周期 toast。

---

## F4 · 房间生命周期收尾（P1）

**问题**：`room_closed` 入队后立即 `conn.Close()` 大概率送不达（`c.send` 从未 close → writePump `!ok` 死代码）；过期 `closeRoom` 按名字匹配，expire→重建同名房间窗口内误踢新房间；`c.roomName`/`c.tempUser` 跨 goroutine 无锁读写（-race 可复现）；tempUser 重绑留幽灵 member。

**位置**：`ws.go:80-92,94-111,84 vs 353/432-443,195,261-268`；`room.go:184-206`。

**修法**：
1. 踢人改「排空后关」：入队 room_closed/CloseMessage 后 `close(c.send)`（`sync.Once`），writePump 排空后写 CloseMessage 退出；disconnect 兜底保留；
2. `Room` 加唯一 `id`；`onExpire` 携带 `*Room`，`closeRoom` 只踢仍绑定该实例的连接；
3. `c.roomName`/`c.tempUser` 读写统一 `h.mu` 保护（或绑定时定值、重绑走受控路径并清旧 member 条目）。

**验收**：Go 测试（`roomExpire` 注入 100ms）——成员实收 `room_closed`；过期+同名重建不误踢；慢客户端剔除后 `peer_left` 送达；并发用例 `-race` 无报告；换 tempUser 重 join 清旧条目。

---

## F5 · 语音通话（P0/P1，iOS 项除外）

**问题**：`call.start('')` → `to:''` 广播 offer（≥3 人房全员 answer 错乱）；`onSignal` 不校验 `event.from`（任何人 bye/ice 作用于你的 pc）；calling 态无 `case 'offer'` → glare 双卡死；`unawaited(onSignal)` 并发 → early ICE 丢失；`Failed` 不 teardown（麦克风不释放）；`leave()` 用 `reset()` 不发 bye；无 peer 时按钮可点永久 calling；`_micMuted`/`_speakerOn` 不复位、speakerOn 从未应用；仅 STUN。iOS `NSMicrophoneUsageDescription` —— **跳过（iOS 不做）**。

**位置**：`view.dart:279`；`wt_call_manager.dart:39-181`；`watch_together_service.dart:353,438`；`signaling/ws.go:334-354`。

**修法**：
1. 服务端 `handleWebRTC`：发送方须已绑定房间；`to` 必填且目标须在同房间（拒绝空 `to`，消除广播面）；
2. 仅 2 人房开放通话按钮（memberCount==2 或有明确 peer）；`start()` 传具体 peerId；无 peer 禁用；
3. `onSignal` 按 `event.from` 过滤；按 peer 串行处理（链式 Future）+ 缓存 remoteDescription 前的 ICE；
4. Glare：收到 offer 时若非 idle，按 tempUser 字典序定 polite/impolite——polite 方放弃自己 offer 重走应答，impolite 方忽略；
5. `Failed`→`_teardown`（Disconnected 观察）；`leave()` 前先 `hangUp()` 发 bye；caller 收到首个 answer 回填 `_peerId`；`reset()` 复位 `_micMuted/_speakerOn`；建联后应用 `setSpeakerphoneOn(_speakerOn)`；
6. WS 断线时 call 置 failed 或 teardown，重连后由用户重新发起。

**验收**：单测（WtCallManager 首批测试）——glare 双发起一方回退最终连通；early ICE 缓存后补 add；第三人 bye/ice 不影响通话；Failed 后 track 停、pc closed、mic 释放；leave 发 bye 对端 teardown；Go 测试——未入房连接发 webrtc 被拒、to='' 被拒。

---

## F6 · 对时与外推（P1）

**问题**：`joined` 采样 `updateIfNeeded(serverTs, serverTs, localNow)` 混用时钟域，可写入减半的错误 offset；无 `hasValidSample` 守卫 → 两端裸本地钟、时钟差直接变 seek 目标且每秒重复；`extrapolateCurrent` 不 clamp；`member_update` 聚合字段被成员侧丢弃（滞后 ~2s）；`isSettling` 恒 false；`_trips` 死字段；整秒精度与 0.1s 阈值脆弱耦合。

**位置**：`wt_signaling_client.dart:154-158,287-310`；`wt_sync_logic.dart:7-46`；`watch_together_service.dart:228,239,294,329-330`；`wt_member_coordinator.dart:8,50,54`。

**修法**：
1. 删除 joined 的 `updateIfNeeded`；
2. member tick：`!hasValidSample` 时只同步 paused 不 seek；`extrapolateCurrent` clamp 到 `[0,duration]`；host 未对时延迟广播；
3. `update`/`update_member` 带发送时刻 `t`，服务端 ack/广播回显 → 客户端做 min-RTT 采样（VT replay_timestamp 模式）；
4. `_handleMemberUpdate` 重建 `room.value` 更新 waitForLoadding/memberCount；
5. seek 后经 `_memberLastSeek` 反馈 `isSettling`（N tick 或收敛前为 true）；删 `_trips`；
6. 位置精度改毫秒（`state.position.inMilliseconds`）。

**验收**：单测——joined timestamp 不污染 offset；无样本时不 seek；外推恒在 `[0,duration]`；member_update 后 `room.waitForLoadding` 立即更新；paused 下 seek 被 settling 抑制；时钟错开 30s 无乱 seek。

---

## F7 · 重连与导航（P1）

**问题**：重连 joined 重放 → member 无条件 `_executeNavigate` → `offNamed` 销毁重建播放器（抖动放大成全员中断）；`_sendJoin` 在 service 订阅前发出，broadcast 丢 joined → 进房无响应；`_executeNavigate` 丢 epid/seasonId（番剧跳错集）+ `bvid!` 空指针；`off:true` 顶掉房间页（通话 UI 消失）；「邀请看当前视频」按钮死代码（currentRoute 恒为 /watchTogether）；无生命周期感知（iOS 后台假活）；`_sendRaw` 断线静默丢；建房先发 join → 必现「房间已重建」误 toast；navigate 与进度非原子。

**位置**：`watch_together_service.dart:312-318,378-389,246-268,128-148,393-398`；`wt_signaling_client.dart:88-91,117-127,230-234`；`page_utils.dart:759-770`；`view.dart:184-189`；`room.go:99-102`。

**修法**：
1. joined/快照 target 与 `_currentTarget` 相同 → 跳过 navigate；`_executeNavigate` 同 bvid/cid 只同步进度；
2. `_sendJoin` 由 service 在订阅后显式触发（或 client 缓存 joined 至有订阅者）；
3. `_executeNavigate` 传 `seasonId/epId`、`bvid==null` guard；navigate 若当前在房间页则不 offNamed（保留房间页栈）；
4. 邀请按钮改用缓存的 lastKnownTarget（`_hostTick` 已在检测）；
5. `_sendRaw` 失败入队或提示；重连退避加 jitter+上限；`connectionState` 接 UI；
6. `WidgetsBinding`/resume 检查 `readyState`，非 open 主动重连 + host 立即 `_hostUpdate()`（iOS 平台分支跳过，做 Android/桌面通用路径）；
7. 建房跳过 `join` 直接 `update`；或 `room_not_exist` host 分支不 toast；
8. navigate 语义 = 新片：服务端 `setTargetLocked` 同时重置 `currentTime=0,paused=false`（消灭非原子窗口）。

**验收**：单测——同 target joined 不 navigate；joined 不丢（低延迟 fake）；navigate 落地含 epid/seasonId；房间页不被 pop；建房无「已重建」toast；集成——断线重连播放器不重建。

---

## F8 · 服务端加固（P1/P2）

**问题**：入向无限流——高速 `update_member` 打满全员 64-buffer 踢掉全房间、`webrtc{to:v}` 定点踢；无连接/per-IP 上限；`h.run`/`handleWebRTC` 锁内 IO；chat 500 **字节**截断切出 `�`；maxRooms TOCTOU；同房间重复 join 幻影 `peer_joined`；已移除 member 的 `update_member` 仍广播。

**位置**：`ws.go:26,94-111,229-233,282-307,334-354,370-372,499-503`；`room.go:128`。

**修法**：per-conn 令牌桶（~10msg/s burst 20）；连接总数+per-IP 上限；锁内 IO 改收集后统一执行；chat 按 rune 截断/超限拒；上限检查进 `GetOrCreate` 锁内；同房重复 join 忽略；未知 member 的 update_member 拒绝。

**验收**：超限连接被踢且 `peer_left` 送达；第 N+1 连接被拒；洪泛下正常成员不被踢；chat 截断为合法 UTF-8；`-race` 全绿。

---

## F9 · 测试 / 文档 / 卫生（P2/P3）

**问题**：3 个 e2e 硬编码 `127.0.0.1:9901` 无 skip（实测必挂）；`wt_raw_ws_probe` 发 ping 收 unknown_type 假断言；e2e 固定 300ms sleep；mirror 外层 25s 使 40s 诊断死代码；`WtDebugServer` 绑 `0.0.0.0:9911` 无鉴权可远控 + URI 打密码；客户端固定 `ws://` 无 TLS；`debugOverlay` 普通 bool 进 `Obx` 不重建；README error code 缺 6 个 + webrtc 广播语义未记录；`tool/README` 未收录 wt 工具；WIP 测试与工具须原子提交；`.gitignore` 无 `.env`；chat 链路死代码；`_speakerOn` 未应用（见 F5）。

**位置**：`test/watch_together/*`；`wt_debug_server.dart:23-53`；`wt_signaling_client.dart:22,57-74,302`；`view.dart:206`；`signaling/README.md`；`tool/README.md`；`.gitignore`。

**修法**：e2e 加 socket 探测 `markTestSkipped`（或 setUp 自起 server）；raw_ws_probe 改 tsync 断言 ack；sleep 改 `waitForEvent`；mirror timeout 修正；DebugServer 绑 `loopbackIPv4`+URI 脱敏；`_normalizeBase` 保留 scheme 支持 `wss://`（timestamp 对应 http/https）；`debugOverlay` 改 RxBool；README/tool README 按现状补齐；`.gitignore` 加 `.env*`/`*.pem`；chat 死代码移除或接 UI（本次移除客户端 dead path，服务端保留转发）。

**验收**：无服务器 `flutter test` 全绿（e2e skip）；probe 断言 tsync_ack；`lsof` 证 DebugServer 绑 127.0.0.1；`git status` 干净；`wss://` 可连或明确拒绝。

---

## F10 · 真机实测轮（2026-09-20，TCL T508N × gnirehtet × wt.raymor.top）

用户报告：「语音正常；房主打开视频点播放立刻被暂停；成员只见标题/UP 主，视频、评论等全挂；一起看入口藏太深」。

### 新发现并修复

| # | 问题 | 位置 | 修法 | 验收 |
|---|---|---|---|---|
| F10-a | **navigate `off:true` 销毁 MainPage → `GStorage.close()` 关掉全部 Hive box** → 详情页只有路由参数（标题/UP 主）能显示，评论/设置读全炸；日志器 `Pref.enableLog` 读已关 box 再抛异常 → Catcher2↔Hive 崩溃循环 → 黑屏。这就是「成员只能看到标题和发布人」的根因 | `watch_together_service.dart _executeNavigate`；`main/view.dart:138 dispose→GStorage.close()` | `off` 仅在当前页本身是观看目标（`/videoV`/`/liveRoom`）时为 true；`Pref.enableLog` 加 try/catch 防崩溃循环；debug server `/navigate`/`/navigateLive` 同步修 | 真机：成员进房 navigate 后详情页完整渲染（封面+评论数+UP 主+相关推荐全出），无黑屏无 HiveError |
| F10-b | **成员 `isBuffering` 永真 → 房主 `waitForLoadding` 永久锁死**（点播放立刻被屏障暂停）。`PlPlayerController.isBuffering` 默认 true，播放器起不来时永远不清 | `wt_member_coordinator` 上报；`room.go anyoneLoadingLocked` | 客户端连续缓冲 20s 停止上报 loading（本地仍重试）；服务端 60s TTL 兜底清陈旧 loading；顺带修 `duration==0` 时片尾豁免误触发 | 真机：成员卡住 60s+ 后服务端屏障自动释放（wait true→false）；单测双端覆盖 |
| F10-c | **悬浮面板 `Positioned` 夹在 `LayoutBuilder` 里 → ParentData 断链**，`Incorrect use of ParentDataWidget` 每帧刷屏，面板退化到 Stack 默认左上角 | `floating_panel.dart` | 撤掉 LayoutBuilder，尺寸改取 `MediaQuery.sizeOf`；新增显式「收起到右缘」按钮（拖拽越过阈值在 216px 卡上很难触发）；无 tooltip（Navigator 之上无 Overlay 祖先） | 真机：面板正常渲染于右下，可拖拽、无红屏、无异常刷屏 |
| F10-d | gnirehtet watchdog `setsid` 在 macOS 不存在 → `nohup` 退化版仍被 launchd **进程组回收** → relay 每 30s spawn→被杀循环，隧道 TCP 全断 → 成员 WSS 秒掉 | ServerX `relay-watchdog/gnirehtet-relay-watchdog.sh` | 无 setsid 时走 `perl -MPOSIX=setsid` 派生新会话（真脱进程组） | 修复后 java relay 跨多轮 watchdog 存活（>70s），隧道不再周期性全断 |
| F10-e | **收编恢复复用屏外坐标** → 边条恢复后卡片留在屏外看不见 | `floating_panel.dart onPanEnd` | 收编时把 `_pos` 改写为贴边后的合法坐标（`Offset(_edge,dy)` / `Offset(w-_cardW-_edge,dy)`），边条 tap 恢复即可见 | 真机：收编→边条→恢复，卡片出现在右缘原位 |
| F10-f | **`isInPipMode` 是普通 static bool**，在 `Obx` 里读不注册依赖 → 进/出 PiP 面板不刷新 | `floating_panel.dart` | 并入已有 400ms `_routeTimer` 轮询 `_inPip` | analyze 通过 |
| F10-g | 收编按钮永远收右缘 + 边条 `top` 未按 92px 高度 clamp → 卡片在左半屏收右缘绕远 / 拖到底部收编后边条半截出屏 | `floating_panel.dart` | 按钮按 `_nearerLeft` 就近收编（图标方向跟随）；边条 `top` clamp `[0, h-96]`；收编时 dy 同步 clamp | 真机：右半屏卡片点「›」收右缘、边条恢复均正常 |
| F10-h | macOS 构建两坑：`flutter_webrtc` 在 SwiftPM 路径下编不出（`FlutterEventSink` 等类型不可见）；`connectivity_plus 7.1+` 无条件调 `NWPath.isUltraConstrained` 需 macOS 26 SDK（本机 Xcode 16.2/SDK 15.2） | 构建环境 + `pubspec.yaml` | `flutter config --no-enable-swift-package-manager`（全局，非仓库改动）；`dependency_overrides: connectivity_plus: 7.0.0`（注释说明可解除条件） | `flutter build macos --debug` 成功产出 PiliSync.app；`local-dev-notes.md` 已记录 |

### 实测环境

- TCL T508N（无 SIM/无 WiFi）经 gnirehtet USB 反向上网（`tun0 10.0.0.2`，ServerX `DEVICES/tcl-phone/`）；`adb forward tcp:9922 tcp:9911` 接 debug server；`tool/wt_host_driver.dart` 在公网 `wss://wt.raymor.top` 扮演房主。
- macOS debug 包（`flutter build macos --debug`）同机做第二端：debug server 占 `127.0.0.1:9911`，可建房/进房/跟随导航；面板右下角固定已截图验证。**注意**：桌面端 debug server 与 adb forward 会抢 9911——手机用 9922 转发隔离。
- 已验证：WSS 穿透隧道建房/进房/对时/navigate/member_update 全通；详情页修复后完整加载；屏障释放端到端生效（macOS 成员走公网生产服务器验证 wait true→false）；面板收编→边条→恢复全链路真机通过。
- **环境限制**：隧道 DNS 对 `bilivideo.com` CDN 域名间歇性 `unknown host`（api.bilibili.com 正常），视频流本身起不来——属隧道环境问题非功能缺陷；真实播放需在正常网络的设备上复验。macOS 桌面截图走 `cua-driver call get_desktop_state`（系统 screencapture 无录屏权限只出壁纸）。

### 悬浮面板交互（`floating_panel.dart`，挂 `main.dart _builder` 根 Stack）

- 移动端：自由拖拽、松手吸附近侧边缘、推过阈值或点「‹/›」按就近侧收编成 30px 边缘条（点按恢复）；全屏/PiP/房间页自动隐藏。
- 桌面端：固定右下角（`Positioned right/bottom:10`），置顶于应用内容之上。

## F11 · 同步体验打磨轮（2026-09-21，4 路审查 + 验证复核）

**状态：全部实施完毕并通过门禁**（go vet + race / flutter test +41 / analyze 无新增）。补注：F11-f 终态新增 `WtConnectionState.failed`（重连耗尽→toast+leave）；悬浮面板卡片/边条增加连接态指示（红点+「连接中…/已断开」文案）；`_memberTick` 增加离线守卫冻结 stale 快照校准（原列残留项，本轮顺手做掉）；`maxMemberLoadingWait` 改为 RoomStore 构造捕获（消测试数据竞争）；e2e 房号改唯一（宿主移交后同名房的 `other_host_syncing` 是正确语义，测试隔离问题非缺陷）。

用户反馈：「同步勉强能用但体验差，尤其一方卡顿时」。4 个审查 agent（客户端同步/VideoTogether 参照/服务端/UX）+ 1 个验证 agent 复核，V15（navigate↔update 竞态）判定误报（TCP 保序 + 单连接串行 handle），其余确认。

### 核心恶性循环（本轮主攻）

**成员落后 δ → seek 校正 → seek 丢缓存触发 buffering → 裸 isBuffering 立即上报 → 全房屏障 → 房主顿挫；且缓冲中的成员继续被发 seek → 缓存反复被丢 → 永远出不来。** 三条链路互相放大，是「一方卡顿全屋难受」的根因。

### 修复清单

| # | 问题 | 位置 | 修法 | 验收 |
|---|---|---|---|---|
| F11-a | **缓冲中的成员仍被发 seek**（`isThisMemberLoading` 只豁免 pause 不豁免 seek）→ seek 丢缓存→更卡→无限循环 | `wt_sync_logic.dart calibrate` | `isThisMemberLoading` 时不发 seek（让缓存填满）；恢复后一次对齐 | 单测：loading member + diff=5s → seekTo==null |
| F11-b | **loading 上报零迟滞**：seek 后 mpv 必 buffering → 一次 1s 校正 seek = 全房 pause→resume 顿挫 | `wt_member_coordinator` tick 末尾上报；`watch_together_service _effectiveLoading` | 持续缓冲 ≥1.5s 才上报 true（dwell）；自己发出的同步 seek 后 2s 内不抬升上报；解除即时 | 单测：seek 后瞬时 buffering 不产生 update_member(true)；连续 2s buffering 才上报 |
| F11-c | **位置整秒精度**：adapter 用 `position.value`(RxInt 秒) 而目标是外推小数 → 落后 δ<1s 的成员稳态周期性误 seek，每次 seek 清空弹幕 | `wt_player_adapter.dart`；`controller.dart positionInMilliseconds` 已存在 | adapter 改读 `positionInMilliseconds`（成员 localTime + 房主 currentTime 同改） | 单测：local=100.0 target=100.3 无 seek；实测 60s 内 CALIBRATE seek ≈0 |
| F11-d | **房主 buffering 毛刺无迟滞**：`reportedPaused` 瞬时采样 isBuffering → paused 广播抖动 → 全员 pause/play 乒乓；且缓冲开始要等 2s tick 才广播 → 成员超前后被拽回 | `wt_playback_coordinator reportedPaused`；`watch_together_service _statusSub` | buffering 持续 ≥1s 才计入 reportedPaused；isBuffering 上升沿（迟滞确认后）立即 `_hostUpdate` 不等 tick | 单测：buffering [t,f,t,f] 各<1s → reportedPaused 稳定；实测房主卡顿成员不回拽 |
| F11-e | **seek 命令不落地**：`controller.seekTo` 内 `await stream.buffer.first` 无超时 + `seek()` fire-and-forget → coordinator 3s timeout 形同虚设，pending seek 可堆积/迟发 | `pl_player/controller.dart` | buffer 等待加超时；seekTo 返回真实完成 future | 单测/插桩：暂停态 seekTo 在 <1s 内落到 mpv |
| F11-f | **断线零感知**：`client.state` 非 Rx；重连 12 次耗尽后静默僵尸房；重连成功误弹「已加入房间/房间已创建」 | `wt_signaling_client`；`watch_together_service _listen/_handleEvent` | service 暴露 `connState` Rx 桥接；断开 toast 节流提示；`WtJoinedEvent` 区分首次/重连（重连弹「已重新连接」）；耗尽 toast+leave | 拔网→1s 内提示；恢复→「已重新连接」；服务器不可达→终态提示非僵尸 |
| F11-g | **屏障压停无反馈**：房主全屏被静默 pause，点播放被静默打回（面板全屏隐藏） | `_applyHostBarrier`；`wt_playback_coordinator` | 首次压停 toast「成员缓冲中，已暂停等待」（节流）；屏障解除自动恢复时 toast「成员已就绪」 | 成员限速→房主端出现解释文案而非静默 |
| F11-h | **成员手动 play 被屏障静默打回** | `wt_sync_logic calibrate`；`_playbackReqSub` 只处理房主 | 屏障强停成员时若本地刚在播 → toast「等待成员缓冲」节流一次 | 成员屏障期点播放→有解释文案 |
| F11-i | **房主断开无继任**：disconnect 只 peer_left，HostId 不变 → 房间冻结 3min 过期；成员永不发 update 无法接管 | `ws.go disconnect`；`room.go` | 房主断开时 HostId 移交最早在线成员 + broadcastRoom（客户端 `_applyAuthoritativeRole` 已有升职路径，零客户端改动） | go test：host 断开后成员 ≤2 tick 收到 isHost=true 快照且其 update 获 ack |
| F11-j | **屏障解除不广播**：`peer_left`/`navigate` 广播无 `waitForLoadding` → loading 成员掉线后房主多停 ~2s | `ws.go` 两处广播；客户端 `WtPeerEvent`/`WtNavigateEvent` | 广播补 `waitForLoadding` 字段；客户端两事件分支读取更新快照 | go test：loading 成员断开 → peer_left.waitForLoadding==false |
| F11-k | **`sameTarget` nil 宽容违反 spec F2**：成员在非视频页（target=nil）的 loading 仍压全房 | `room.go sameTarget` | 成员侧 target==nil → 不计入聚合 | go test：无 target loading 成员 → waitForLoadding==false |
| F11-l | **片尾豁免严格浮点相等** `CurrentTime == Duration` | `room.go anyoneLoadingLocked` | `Duration>0 && CurrentTime >= Duration-0.5` | go test：99.9/100 + loading → false |
| F11-m | **update_member 无条件全员广播 + 无房间人数上限**：N²/2s 放大，重连风暴级联 | `ws.go handleUpdateMember/broadcast` | 状态未变时只回显 sender（保留 `t` 对时采样）；`maxMembersPerRoom=32` | go test：两条相同 update_member → 仅一条广播；压测 egress 下降 |
| F11-n | **pongWait 余量仅 6s 且普通消息不刷 deadline** → 弱网排队误踢 | `ws.go` 常量+readPump | `pongWait` 60→120s；ReadMessage 成功后无条件刷 deadline | 模拟不回 pong 但发业务消息的连接存活 ≥110s |
| F11-o | **navigate 重置 playing@0** → 窗口期 join/重连成员被 seek 回片头 | `room.go setTargetLocked` | 重置时 `Paused=true`（成员停在原地等真实 update） | go test：navigate 后快照 paused==true |
| F11-p | `room_not_exist` 文案误导向（「房间已关闭或过期」→ 输错房号的人以为房被关） | `watch_together_service _handleError` | 改「房间不存在或已过期」 | 输入不存在房号 → 文案含「不存在」 |

### 残留/不做（记录备查）

- **room→clients 广播索引**：broadcast 仍全 hub 扫描，F11-m 去重后小房间（≤5 人）无感；大房间场景再优化。
- **成员心跳 TTL（VT IsJoined 10s）**：App 挂起时 dart isolate 停 → WS pong 停 → 120s pongWait 踢除 + LoadingSince 60s TTL 已双兜底；列为观察项。
- ~~**成员离开视频页后 coordinator 仍校准后台 player**~~：F12-l 已修（本地 target 可证明不同时跳过校准）。
- **断线期间成员快照 stale 仍外推/seek**：~~不做~~ 已随本轮修复——`_memberTick` 增加离线守卫，`connState != connected` 时冻结校准，避免断线期间持续 seek、重连后大跳变（VT 的 HTTP 兜底仍不做）。
- **面板 per-member loading 显示 / 等待时长 / WaitForLoadding 用户开关 / play() 失败红字提示**：UX 增强，下一轮。
- **tsync 偏移重收敛**（min-RTT 只进不退）、**broadcastRoom per-recipient marshal**：性能项，观察。
- **V15 navigate↔update 竞态**：验证判定误报（同连接 TCP 保序），不修。

---

## F12 · 二轮深挖（2026-09-21，4 路审查 + 1 路验证复核）

**状态：全部实施完毕并通过门禁**（go vet + race ✅ / flutter test +52 全绿含本地信令 e2e 实跑 ✅ / analyze 无新增 ✅）。新增回归：Dart 侧 F12-a/b/c/d/m 服务级 + F12-f 通话 + F12-i/m 协调器与 calibrate 层；Go 侧 F12-q/r/s/t/u/v/x/y/z/aa 十项。残留：F12-l（离页成员校准跳过）与 F12-n（navigate 重试）涉及 `Get.currentRoute`/`PageUtils` 无单测路径，验收靠真机；V12 误报已复核排除。

验证结论：26 确认 / 4 部分成立 / 1 误报（V12 glare「caller 恒 impolite」——`_handleSignal` 在 glare 分支前已把 `_peerId` 重绑为 `event.from` 真实 uuid，双侧必一 polite 一 impolite，判定误报不修）。

### 客户端修复项

| # | 问题 | 位置 | 修法 | 验收 |
|---|---|---|---|---|
| F12-a | **宿主 buffering 边沿广播是死代码**：上升沿 Timer(1s)→`_hostUpdate`→`_hostBufferingDwelled` 里 `_hostBufferingSince ??= now` 在触发瞬间才播种 → `now-since=0<1.0` 恒 false，stall 实际延迟 2–3s（比改动前更差） | `watch_together_service.dart` `_bufferingSub`/`_hostBufferingDwelled` | 上升沿回调时立即播种 `_hostBufferingSince = now`，dwell 从边沿计起 | 单测：host buffering 1s 后 update 携带 paused=true |
| F12-b | **seek 后 2s 静默窗是死代码**：coordinator 算好 `isBuffering && 距上次 seek≥2s` 传给 `reportLoading`，service 的 `_reportLoading([bool? _])` 丢弃参数重算 → 静默从未生效 | `wt_member_coordinator.dart`、`watch_together_service._reportLoading` | `_reportLoading` 采用入参作为 raw 信号喂给 dwell/cap；`_memberHeartbeat` 沿用裸 raw（心跳路径无 seek 上下文） | 单测：seek 后 1s 内 isBuffering 不产生 update_member(true) |
| F12-c | **room_full/not_in_room/already_bound 只 toast 不退出** → 僵尸房 + 每 2s 心跳打回 toast 死循环 | `watch_together_service._handleError` | 终态错误码走 `leave()` + 明确文案（「房间已满」等） | 单测：room_full → inRoom=false |
| F12-d | **离线守卫在 connected↔joined 间留 ~1RTT 陈旧快照窗口**：connected 即解冻，用断线前快照外推发大 seek | `watch_together_service._memberTick` | `_awaitingFreshSnapshot` 标志：断线时置位，`WtJoinedEvent`/`WtRoomUpdateEvent` 到达才解冻 | 断线重连场景不产生旧快照外推 seek |
| F12-e | **min-RTT 只进不退 + 重连不 reset** → 换网络后 offset 永久污染 | `wt_signaling_client._openSocket`、`wt_sync_logic.WtTimeSync` | 新 socket 建立时 `timeSync.reset()`（host 侧有 hasValidSample 门控，安全） | 单测：重连后 offset 重新采样 |
| F12-f | **通话可永久卡 calling**：`_peerId='peer'` 别名对不上 `onPeerLeft` 的真实 uuid；offer 建联异常被 `_signalWork.catchError` 吞；`start` 不查 socket 态 | `wt_call_manager.dart` | calling 加 answer 超时（15s→failed+toast）；未绑定别名时对端离开即 reset；offer 处理包 try/catch 置 failed；start 前查 connState | 单测：对端应答前离开 → 回到 idle |
| F12-g | **`leave()` 先断 socket 再 `call.reset()`** → bye 永远发不出 | `watch_together_service.leave` | `call.reset()` 移到 `client.disconnect()` 前 | 单测：bye 信号进入 RecordingSignaling |
| F12-h | **角色切换清理不全**：host→member 降级不重置 `_hostBufferingSince/Timer`；member 态播放器重建后 `_playbackReqSub` 等绑死旧实例 | `_applyAuthoritativeRole`、`_ensureStatusSub` 调用点 | 降级时重置 host buffering 状态；`_ensureStatusSub` 提到 `_tick` 公共段 | 单测：member 态换播放器后 barrier toast 仍生效 |
| F12-i | **成员 seek 豁免无上限**：isBuffering 永真 → 成员永不回正（上报有 20s cap，豁免没有，不对称） | `wt_sync_logic.calibrate`、`wt_member_coordinator` | 豁免仅在缓冲 run < cap 时生效，超时允许一次对齐 seek | 单测：loading run>cap 且 diff 大 → 允许 seek |
| F12-j | **`_executeAction` 串行 3×3s timeout 最坏 ~9s 持 _ticking**，期间心跳也被跳过 | `wt_member_coordinator`、`watch_together_service._tick` | `_memberHeartbeat` 移到 `_ticking` 闸门外 | 挂起 seek 时心跳照常 |
| F12-k | **`seekTo` 的 duration==0 deferred 分支**：future 立即完成、timeout 失效、落地陈旧 position | `pl_player/controller.dart` | deferred seek 用 Completer，duration 流发射执行 seek 后才完成；超时挂起路径同样受控 | 单测：duration 未就绪时 seekTo 不提前完成 |
| F12-l | **成员在无关视频页仍被校准拖拽**（tick 只查 hasPlayer/isLive 不比 target） | `watch_together_service._memberTick` | 本地 `_detectTarget()` 与房间 target 可证明不同（均非空且不匹配）时跳过校准 | 单测：成员在不同 bvid 页 → 无 seek/pause 命令 |
| F12-m | **音频中断与同步打架**：成员被 calibrate 拉回播放；房主瞬态中断 pause 永久吞掉屏障自动恢复 | `audio_session`、`wt_playback_coordinator`、`controller.pause` | 成员侧外部 pause 后 10s 内 calibrate 不发 play；房主侧 `isInterrupt` 的 pause 不入 `_playbackRequests` | 单测：中断 pause 后成员不被立即拉回；房主屏障解除仍自动恢复 |
| F12-n | **成员 navigate 失败静默滞留旧页**：viewPgc 失败无重试无回报；连续 navigate 的 pgcInfo 可乱序落地 | `watch_together_service._followNavigate`、`page_utils.viewPgc` | memberTick 里校验：本地 target 可证明与房间不符且距上次 navigate >10s → 重试；`_navigateGen` 代际丢弃陈旧解析 | 单测：viewPgc 失败后下个周期重试 navigate |
| F12-o | **`_startTimeSync`/`_openSocket` 交错**：tsync Timer 丢引用泄漏；旧 socket 被顶掉不 close → 服务端僵尸 conn | `wt_signaling_client` | generation counter：openSocket 完成后校验代际，过期 socket 直接 close；tsync 用同一代际守卫 | 单测：交错后只保留最新 socket/timer |

### 服务端修复项

| # | 问题 | 位置 | 修法 | 验收 |
|---|---|---|---|---|
| F12-p | **同名 tempUser 断线/加入竞态**：disconnect 的 stillBound 检查与 removeMember 分属两个临界区 → 新 conn 认领的 member 被删；幂等 join 分支不补 upsert → 不可自愈 | `ws.go` disconnect/handleJoin、`room.go` | removeMember 与 stillBound 判定合并到 h.mu 临界区（锁序 h.mu→room.mu 安全）；幂等 join 与 update_member 路径补 upsertMember 自愈 | go test：竞态注入后 member 记录仍在 |
| F12-q | **transferHost check-and-set 非原子**：断开处理间隙的 takeover 会被移交覆盖 | `ws.go` disconnect、`room.go` | `transferHostIfStill(departed)`：同一 room.mu 内 `HostId != departed → return ""` | go test：间隙 takeover 不被移交覆盖 |
| F12-r | **未绑定 conn 可冒用在线成员 tempUser 夺权**（tempUser 明文广播可窃取） | `ws.go handleUpdate` | update 的 tempUser 命中在线 member 且本 conn 未绑定该身份 → `identity_in_use` 拒绝 | go test：冒名 update 被拒 |
| F12-s | **update 路径绕过 maxMembersPerRoom** | `ws.go handleUpdate` | upsert 前检查：非 host 且非已有 member 且满员 → room_full | go test：满员房 update 被拒 |
| F12-t | **webrtc 单播按 tempUser map 序随机命中**，僵尸 conn 吞信令 | `ws.go handleWebRTC` | 投递给全部匹配 conn（不改初版语义，僵尸自然失效） | go test：双 conn 同 tempUser 均收到 |
| F12-u | **文本字段无上限** → 1MB×10/s×扇出32 带宽放大 | `ws.go` 各 handle* | 字段 cap：tempUser≤64、room≤128、title≤256、url≤2KB、webrtc payload≤64KB | go test：超限字段被拒或截断 |
| F12-v | **playback 零校验**：`duration=0.001` 使 `CurrentTime>=Duration-0.5` 恒真 → 屏障永久豁免；负 rate 透传 | `ws.go handleUpdate`、`room.go anyoneLoadingLocked` | 片尾豁免要求 `Duration>=1.0`；currentTime<0→0；rate 钳到 [0.1,10] | go test：畸形 duration 不再豁免屏障 |
| F12-w | **broadcast 按 roomName 字符串匹配**：过期删除→重建同名房窗口内新旧 conn 互收事件 | `ws.go broadcast` 及调用点 | 改按 `c.room == room` 实例匹配 | go test：重建后旧 conn 不收新房事件 |
| F12-x | **`member_update` 回显缺 timestamp** → 成员对时样本只剩 60s tsync（VT 每次心跳都有样本） | `ws.go handleUpdateMember` | payload 补 `"timestamp": now()`（广播与回显同带） | go test：回显含 timestamp |
| F12-y | **房主自身 loading 进入屏障聚合** → 房主卡顿给自己 toast「成员缓冲中」+自 pause（VT 中房主不走 loading 通道） | `room.go anyoneLoadingLocked`、`_memberHeartbeat` | 聚合排除 `m.TempUser == r.HostId` | go test：host loading 不抬屏障 |
| F12-z | **成员心跳无新鲜度 TTL**（VT IsJoined=10s）：僵尸 conn 的 stale isLoading 要等 60s 总 TTL | `room.go Member` | `Member.LastHeartbeat`（setLoading/join 刷新），屏障聚合要求 `<15s` 新鲜 | go test：15s 无心跳的 loading 成员不计屏障 |
| F12-aa | **屏障翻转无主动广播**：setLoading 的 changed 不比屏障计算值，TTL 到期翻转被 dedup 吞 | `room.go setLoading` | `changed = changed || prevBarrier != newBarrier` | go test：TTL 到期后一次心跳即广播 false |
| F12-ab | **member_update 的 waitForLoadding 客户端 `?? false`**：老服务端缺字段时被误读为 false 清屏障 | `wt_signaling_client` | 改可空透传，缺失时不改快照 | 单测：缺字段不清屏障 |

### 残留/不做（记录备查）

- **V31 房间过期自动恢复**（VT 轮询式 rejoin）：需「等待房间重建」态设计，下一轮。
- **V32 房间状态持久化**（进程被杀丢房）：下一轮。
- **V27 空房 HostId 残留可被旧成员名恢复**：空房内任意 fresh tempUser 的 update 本就可 takeover（VT userIds 语义），tempUser 是 uuid 不可猜，面小，不修。
- **V20 剩余缺口**（host 停更场景下屏障翻转不扩散）：F12-aa 已覆盖主要路径。
- **跨 goroutine 事件乱序**（member_update vs peer_left 屏障值瞬时不一致）：下一事件自愈，不加序号机制。
- **V12 glare 双 impolite**：误报不修。

---

## 验收总闸

- `cd signaling && go vet ./... && go test -race -count=1 ./...` 全绿
- `fvm flutter test test/watch_together/` 全绿（e2e 需 9901 服务器时自动 skip 或自起）
- `fvm flutter analyze` 对改动文件无新增 issue
