# Flutter 全套回归

两次提交都使用 Flutter 3.47.5、Dart 3.13.4 和同一份测试锁。每次运行都用该提交的 Go 源码启动真实信令服务，监听 `127.0.0.1:9901`。镜像测试启动的 `fvm dart` 被转交给同一 SDK 中的 Dart。Flutter 按单并发执行整个 `test/` 目录。

| 实测 | 基线 314adb86 | 候选 d11e7657 |
| --- | ---: | ---: |
| 原仓库锁严格解析的退出码 | 65 | 65 |
| 测试锁严格解析的退出码 | 0 | 0 |
| 最终全套通过数 | 104 | 105 |
| 最终跳过 / 失败 | 0 / 0 | 0 / 0 |

根清单要求 `gt3_flutter_plugin ^0.1.0`，原锁缺少这项记录。两份 `original-lock.log` 均记录了严格解析失败。测试使用的 [补丁](test-lock.patch) 仅补入该包 0.1.0 及其 SHA-256，现有依赖版本及 Git 提交均沿用原锁。执行后脚本恢复临时工作树的原始锁文件。原锁与测试锁的完整 SHA-256 见 [汇总](summary.json)。

首次运行的两个镜像用例均超时，expanded reporter 在基线从 00:12 跳到 50:38，在候选从 00:12 跳到 05:46。首次输出保存在 [基线](before-clock-jump.log)、[候选](after-clock-jump.log) 和 [汇总](first-attempt.json)。重新执行同一个全套命令时，两端镜像都输出了 `done`。最终原始输出见 [基线](before-tests.log) 和 [候选](after-tests.log)。

## 在 macOS 重跑

从仓库根目录运行。准备一个专用于本次构建的 Flutter 3.47.5 macOS arm64 SDK，设置 `PILISYNC_TEST_SDK` 为它的绝对路径。SDK 压缩包哈希、框架提交和实际应用的补丁在 [SDK 配置日志](sdk-setup.log)。

```sh
suite_tmp=$(cd "$(mktemp -d)" && pwd -P)
suite_sdk=$(cd "${PILISYNC_TEST_SDK:?请先设置独立的 Flutter SDK 路径}" && pwd -P)
suite_artifacts="$PWD/docs/evals/artifacts/flutter-suite"
export PUB_CACHE="$suite_tmp/pub"

git worktree add --detach "$suite_tmp/before" 314adb86a46f49ec0340ed2f3d9da62af28dbd67
git worktree add --detach "$suite_tmp/after" d11e7657f60f543c1f02fe001d42a2014dbc0b79

(
  cd "$suite_tmp/after" &&
  git apply "$suite_artifacts/test-lock.patch" &&
  "$suite_sdk/bin/flutter" --no-version-check pub get --enforce-lockfile &&
  git apply --reverse "$suite_artifacts/test-lock.patch"
)

python3 "$suite_artifacts/patch_macos.py" --repo "$suite_tmp/before" \
  --sdk "$suite_sdk" --material-cache "$PUB_CACHE/hosted/pub.dev/material_ui-1.4.0"

caffeinate -dims -t 180 python3 "$suite_artifacts/run.py" \
  --baseline "$suite_tmp/before" --candidate "$suite_tmp/after" \
  --sdk "$suite_sdk" --pub-cache "$PUB_CACHE" --out "$suite_tmp/results"
```

首次准备需要下载锁定的 Flutter 包和 Git 对象。Go 回环服务的构建还需要 Go 模块缓存中的 `github.com/gorilla/websocket v1.5.3`，可提前在 `signaling/` 运行 `go mod download`。执行复测时请给本地端口 9901 留空。
