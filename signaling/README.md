# PiliSync Signaling Server

一起看（Watch Together）功能的信令服务器。协议语义对齐 VideoTogether（`room/update` 单写者、快照广播、客户端外推校准），传输为纯 JSON over WebSocket。

## 运行

```bash
go build -o signaling-server .
./signaling-server   # 默认监听 :9901
```

- `GET /timestamp` — 返回 `{"timestamp": <unix 秒 float>}`，用于 HTTP 对时兜底
- `GET /stats` — `{"rooms": n, "clients": n, "server_time": t}`
- `WS /ws` — 信令主通道

调试探针：

```bash
go run ./cmd/probe        # Go WS 客户端
dart run probe_dart.dart  # Dart WS 客户端（需在项目根目录跑）
```

## 消息协议

所有消息为单行 JSON。通用字段：`room`（房间名）、`password`（明文，服务端 MD5 存储）、`tempUser`（客户端 uuid）。

### 客户端 → 服务器

| type | 字段 | 说明 |
|---|---|---|
| `join` | room/password/tempUser | 成员加入；房主重连也可用 |
| `update` | playback{playbackRate,currentTime,paused,duration,lastUpdateClientTime,url,videoTitle,target} | **单写者**：仅房主可发；首条 update 创建房间；新 tempUser 可夺权（VT 兼容） |
| `update_member` | isLoading | 成员上报缓冲状态 |
| `navigate` | target{type,bvid,cid,epid,roomId,title} | 房主切换视频，全员跟随 |
| `webrtc` | to, payload | WebRTC SDP/ICE 转发（点对点投递） |
| `chat` | text | 聊天（≤500 字节） |
| `tsync` | t | 对时采样，回复 `tsync_ack{t,server}` |
| `pong` | t | 响应服务器 JSON ping，重置读超时 |

### 服务器 → 客户端

| type | 字段 | 说明 |
|---|---|---|
| `joined` | room 快照, timestamp, isHost | join 确认 |
| `update_ack` | room 快照 | update 确认（仅发送者） |
| `room` | room 快照 | 房主状态广播（skip 发送者） |
| `member_update` | tempUser, isLoading, waitForLoadding, memberCount | 缓冲状态聚合 |
| `navigate` | from, target | 跟随跳转 |
| `peer_joined` / `peer_left` | tempUser, memberCount | 成员进出 |
| `webrtc` | from, payload | WebRTC 转发 |
| `chat` | from, text, ts | 聊天 |
| `ping` / `pong` | t | 应用层心跳（另有 WS 层 ping/pong，54s/60s） |
| `room_closed` | — | 房间过期被回收，客户端应退出 |
| `error` | code | room_not_exist / wrong_password / other_host_syncing / host_only / not_in_room / bad_request / room_limit |

## 关键语义

- **单写者**：只有 `hostId == tempUser` 能 update/navigate；未见过的新 tempUser 直接夺权（掉线重连即拿回），老房主再写报 `other_host_syncing`
- **快照外推**：成员用 `real = currentTime + (now - lastUpdateClientTime) * playbackRate` 本地外推，服务端不转发逐帧
- **TTL**：3 分钟无 update 自动回收，回收时向房间内所有连接发 `room_closed` 并断开
- **安全**：密码 MD5；房间数上限 10000；聊天 500 字节；单条消息 1MB 上限；慢客户端（send buffer 满）直接剔除

## 测试

```bash
go test -race ./...
```
