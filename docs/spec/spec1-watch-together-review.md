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

## 验收总闸

- `cd signaling && go vet ./... && go test -race -count=1 ./...` 全绿
- `fvm flutter test test/watch_together/` 全绿（e2e 需 9901 服务器时自动 skip 或自起）
- `fvm flutter analyze` 对改动文件无新增 issue
