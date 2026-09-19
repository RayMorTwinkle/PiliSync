# PiliSync Signaling Server

一起看（Watch Together）功能的信令服务器。协议语义对齐 VideoTogether（`room/update` 单写者、快照广播、客户端外推校准），传输为纯 JSON over WebSocket。

## 运行

```bash
go build -o signaling-server .
./signaling-server   # 默认监听 :9901
```

- `GET /timestamp` — 返回 `{"timestamp": <unix 秒 float>}`，用于 HTTP 对时兜底
- `GET /ice-servers` — `{"iceServers": [...]}`，客户端建 RTCPeerConnection 前拉取（见下方 TURN）
- `GET /stats` — `{"rooms": n, "clients": n, "server_time": t}`
- `WS /ws` — 信令主通道

## TURN（语音通话 NAT 穿透）

API token 属于长效密钥，**只能放服务端**——打进客户端包等于公开。机制：服务端用 `TURN_API_TOKEN` 代取 Cloudflare 的短期 ICE 凭据，`GET /ice-servers` 把凭据下发给客户端；客户端永远看不到 token。

```bash
# signaling/.env（已 gitignore，参考 .env.example）
TURN_KEY_ID=<cloudflare turn key id>
TURN_API_TOKEN=<cloudflare turn api token>

set -a; . ./.env; set +a
./signaling-server
```

未配置时 `/ice-servers` 返回 STUN-only 兜底；上游失败先吃缓存、再降级 STUN，通话在非对称 NAT 下仍可用。凭据按半生命周期缓存。

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
| `update` | playback{playbackRate,currentTime,paused,duration,lastUpdateClientTime,url,videoTitle,target}, t | **单写者**：仅房主可发；首条 update 创建房间；新 tempUser 可夺权（VT 兼容）；`t` 回显用于对时采样 |
| `update_member` | isLoading, target?, t | 成员上报缓冲状态与所在页面；`t` 仅在回显给发送者时用于对时 |
| `navigate` | target{type,bvid,cid,epid,seasonId,roomId,title} | 房主切换视频，全员跟随 |
| `webrtc` | to, payload | WebRTC SDP/ICE 转发（点对点投递，`to` 必填）；`to:"host"` 解析为房主，`to:"peer"` 解析为房间内唯一对方（仅双人房有效） |
| `chat` | text | 聊天（≤500 字符，UTF-8 安全截断） |
| `tsync` | t | 对时采样，回复 `tsync_ack{t,server}` |
| `pong` | t | 响应服务器 JSON ping，重置读超时 |

### 服务器 → 客户端

| type | 字段 | 说明 |
|---|---|---|
| `joined` | room 快照, timestamp, isHost | join 确认 |
| `update_ack` | room 快照+isHost, t | update 确认（仅发送者） |
| `room` | room 快照+isHost | 房主状态广播（per-recipient isHost） |
| `member_update` | tempUser, isLoading, waitForLoadding, memberCount, t | 缓冲状态聚合（含发送者回显） |
| `navigate` | from, target | 跟随跳转 |
| `peer_joined` / `peer_left` | tempUser, memberCount | 成员进出 |
| `webrtc` | from, payload | WebRTC 转发 |
| `chat` | from, text, ts | 聊天 |
| `ping` / `pong` | t | 应用层心跳（另有 WS 层 ping/pong，54s/60s） |
| `room_closed` | — | 房间过期被回收，客户端应退出 |
| `error` | code | bad_json / unknown_type / bad_request / room_not_exist / wrong_password / already_bound / not_in_room / missing_playback / missing_isLoading / missing_target / missing_to / other_host_syncing / host_only / peer_not_found / peer_ambiguous / room_limit / rate_limited / connection_limit |

## 关键语义

- **身份绑定**：连接一旦 join/update 成功即绑定 `(room, tempUser)`，之后的所有消息必须是同一身份；快照**永不下发 hostId**，客户端只通过 per-recipient `isHost` 得知自己的角色——hostId 是写权限凭证，广播它等于把房主钥匙发给全员
- **单写者 + 夺权**：只有房主能 update/navigate；房间内维护 `seen`（曾写过 update 的 tempUser 集合，VT userIds），**新 tempUser 的首条合法 update 直接夺权**（房主重启换 uuid 也能拿回房间），已见过但非房主的写入报 `other_host_syncing`；`join` 不登记夺权资格
- **成员生命周期**：`members` 跟踪在线连接（join/update 时登记、断连即删），memberCount 就是在线数；`seen` 只写不删、随房间消亡——两张表语义不同，不可混用
- **快照外推**：成员用 `real = currentTime + (now - lastUpdateClientTime) * playbackRate` 本地外推，服务端不转发逐帧
- **TTL**：3 分钟无 update 自动回收；回收时**先排空发送队列再断连**，保证 `room_closed` 可达；room 有内部 id，过期房间不会误踢同名新房间的成员
- **聚合**：`waitForLoadding` 只统计与房间当前 target 同页的成员，片尾（currentTime==duration）缓冲不阻塞全员
- **安全**：密码 MD5；房间数上限 10000；连接数上限 5000；单连接消息限流（令牌桶）；聊天 500 字符 UTF-8 截断；单条消息 1MB；慢客户端（send buffer 满）剔除；`webrtc` 必须有合法目标（uuid/"host"/"peer"），空 `to` 拒绝

## 测试

```bash
go test -race ./...
```
