# tool/

开发/测试辅助工具。除注明外均在项目根目录用 `fvm dart run` 执行。

## jnigen

`dart run tool/jnigen.dart` — JNI 绑定生成。

## 一起看（Watch Together）本地调试工具

需要本地信令服务器：`cd signaling && go run .`（监听 `:9901`）。

| 工具 | 命令 | 说明 |
|---|---|---|
| 连接探针 | `fvm dart run tool/wt_connection_probe.dart` | 建房→加入→joined 冒烟测试，验证信令链路连通 |
| 虚拟成员镜子 | `fvm dart run tool/wt_mirror.dart --room=<房号> [--buffer-seconds=N] [--duration=S]` | 无 UI 的协议级 member：接收房主快照、按 calibrate 输出指令、周期性上报 loading，JSONL 输出到 stdout |

对应测试：`test/watch_together/wt_signaling_e2e_test.dart`、`wt_mirror_e2e_test.dart`、`wt_raw_ws_probe_test.dart` —— 服务器不在本机时自动 skip。

另：debug 构建内置 `WtDebugServer`（`127.0.0.1:9911`，仅 loopback），可用 `adb forward tcp:9911 tcp:9911` 后通过 `/status`、`/wt/create`、`/wt/join`、`/navigate`、`/play`、`/pause`、`/seek`、`/speed` 远程驱动真机。
