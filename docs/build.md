# 构建说明：Flutter SDK 补丁

PiliSync（继承自 PiliPlus/PiliNara）**无法用原版 Flutter SDK 直接编译**。应用代码引用了若干经「魔改」的 Flutter 框架行为（如 `PageView`/`TabBarView` 的 `horizontalDragGestureRecognizer` 参数、定制滚动物理、文本选择行为等），这些符号在 stock SDK 中不存在，构建前必须先打补丁。

补丁的全部清单见 `lib/scripts/patch.ps1`（上游为 Windows/PowerShell 设计，共三层）：

## 补丁的三个层级

| 层级 | 打到哪里 | 内容 |
|------|----------|------|
| Flutter SDK 本体 | `$FLUTTER_ROOT`（如 `~/fvm/versions/3.47.5`） | ~21 个 patch：scrollable/scroll_position/scrollable_gesture、text_field/selectable_region/editable_text/text_selection、modal_barrier、mouse_cursor、image_anim、layout_builder、navigation_drawer、popup_menu、fab、draggable_scrollable_sheet、scaffold、text、text_painter、sliver、refresh_indicator、null_safety_for_selectable_region、predictive_back_page_transitions_builder 等 |
| pub 缓存框架包 | `~/.pub-cache/hosted/pub.dev/material_ui-<ver>`、`cupertino_ui-<ver>` | `lib/scripts/material/*`（10 个）、`lib/scripts/cupertino/*`（iOS 专用） |
| repo 内 lib/ 源码 | 本仓库工作区 | iOS 专用：`bottom_sheet_ios_piliplus.patch`（改 mini_scaffold/common_slide_page）、`geetest_ios.patch`（接入 gt3 验证码插件：加 pubspec 依赖 + 新建 `geetest_plugin.dart` + 登录弹窗 hook）；另有 `bottom_sheet_ios_flutter.patch`、`scroll_view.patch`、`navigator.patch` 打 SDK |

**依赖版本对齐**：当前实测可用组合为 Flutter **3.47.5**（`.fvmrc`）、material_ui **1.4.0**、cupertino_ui **1.1.2**、protobuf **6.1.0**（6.0.0 会导致 `.pb` 生成代码不兼容）。material_ui/cupertino_ui 补丁是按版本路径打的，升级这两个包后要重新打对应缓存目录。

## 非 Windows 平台如何打补丁

`patch.ps1` 是 PowerShell 脚本。在 macOS/Linux 上等价做法是手动 `git apply`：

```bash
cd <repo>
REPO=$PWD
FLUTTER_ROOT=~/fvm/versions/3.47.5   # fvm flutter --version 确认

# 1) SDK patch：通用 21 个全打
cd "$FLUTTER_ROOT"
for p in scrollable scroll_position scrollable_gesture text_field \
         selectable_region editable_text modal_barrier text_selection \
         mouse_cursor image_anim layout_builder navigation_drawer \
         popup_menu fab null_safety_for_selectable_region \
         draggable_scrollable_sheet scaffold text text_painter sliver \
         refresh_indicator predictive_back_page_transitions_builder; do
  git apply "$REPO/lib/scripts/$p.patch" || echo "FAILED: $p"
done

# 2) pub 缓存 patch（先 flutter pub get 让包落盘）
cd ~/.pub-cache/hosted/pub.dev/material_ui-<ver>
for p in "$REPO/lib/scripts/material/"*.patch; do git apply "$p"; done
cd ~/.pub-cache/hosted/pub.dev/cupertino_ui-<ver>
for p in "$REPO/lib/scripts/cupertino/"*.patch; do git apply "$p"; done

# 3) iOS 额外（SDK 侧 + repo 侧）
cd "$FLUTTER_ROOT"
for p in scroll_view bottom_sheet_ios_flutter navigator; do
  git apply "$REPO/lib/scripts/$p.patch" || echo "FAILED: $p"
done
cd "$REPO"
git apply lib/scripts/bottom_sheet_ios_piliplus.patch
git apply lib/scripts/geetest_ios.patch && flutter pub get   # geetest 新增依赖
```

> patch.ps1 里 iOS 平台只打 iOS 专用项，通用 21 个是所有平台共用的（脚本 `Common` 段）。以 `patch.ps1` 为准核对最终清单。

## iOS 模拟器的两个坑

1. **`gt3_flutter_plugin`（GeeTest 验证码）没有 arm64-simulator slice**，模拟器跑不起来。临时方案（**不要提交**）：从 `pubspec.yaml` 删掉 `gt3_flutter_plugin` 依赖，并移除 `lib/pages/login/geetest/geetest_webview_dialog.dart` 里的 `return GeetestPlugin.geetest(gt, challenge);` 早退行与对应 import——回退到 WebView 验证码。真机 release 构建前恢复 `git apply lib/scripts/geetest_ios.patch`。
2. **iOS 27+ 模拟器拒绝未签名 framework**：`flutter build ios --simulator` 出的 app 起不了，需 `codesign --force --deep --sign - Runner.app` 补签。

## Release 打包流程（v2.9.3 实作）

```bash
# 版本元数据（等价 build.ps1）
CODE=$(git rev-list --count HEAD)
printf '{"pili.name":"2.9.3","pili.code":%s,"pili.hash":"%s","pili.time":%s}' \
  "$CODE" "$(git rev-parse HEAD)" "$(date +%s)" > pili_release.json
sed -i '' "s/^version: .*/version: 2.9.3+$CODE/" pubspec.yaml   # 构建期写入，不提交

# iOS：unsigned IPA（AltStore/Sideloadly 侧载）
fvm flutter build ios --release --no-codesign --dart-define-from-file=pili_release.json --no-pub
ln -sf ./build/ios/iphoneos Payload
find Payload/Runner.app/Frameworks -type d -name "*.framework" \
  -exec codesign --force --sign - --preserve-metadata=identifier,entitlements {} \;
zip -r9 PiliSync_ios_2.9.3.ipa Payload/Runner.app

# macOS：dmg
fvm flutter build macos --release --dart-define-from-file=pili_release.json --no-pub
hdiutil create -fs HFS+ -volname PiliSync \
  -srcfolder build/macos/Build/Products/Release/PiliSync.app PiliSync_macos_2.9.3.dmg
```

## 工作区「脏文件」是预期状态

repo 侧 patch（geetest、bottom_sheet）+ iOS 构建产物（`ios/Podfile`、`Podfile.lock`、`project.pbxproj`、`Runner.xcscheme`）会留在工作区显示为修改——上游 CI 设计即「patch 随构建打、不进 git 历史」。**不要 `git checkout .` 清掉**，下次构建还用得着。例外：上面说的模拟器 gt3 stub 才是需要警惕的本地改动。

## 一起看 / 信令

- 信令服务端：`signaling/`（Go，`gorilla/websocket` 唯一依赖），`go build` 后默认监听 `:9901`；线上 `wss://wt.raymor.top`（ServerX 部署）。
- 调试控制面：`wt_debug_server.dart` 在 `kDebugMode` 下监听 loopback `:9911`，可外部驱动建房/跳视频/读状态（release 构建被剔除）。
- 同机双开 E2E：`open -n` 会被单实例拦——复制 `.app` 改 `Info.plist` 的 `CFBundleIdentifier` 重签即可双开。
