# 本地开发环境笔记（PiliSync 一起看开发）

## Flutter SDK 补丁（必须）

上游 PiliPlus/PiliNara 依赖一批 Flutter SDK 魔改（把 `DraggableScrollableSheetState` 等私有类公开等）。
换机器/升级 Flutter 后必须重新打，否则 `flutter analyze` 会出现 ~100 个上游文件编译错误（集中在 `lib/common/widgets/draggable_sheet/dyn.dart` 等）。

上游依据：
- 发布流程走 `.github/workflows/build.yml` → `lib/scripts/patch.ps1 android`
- `android.yml` 里引用的 `*_patch.diff` 是死链接（404，靠 `|| true` 掩盖），不要照抄

本机复刻（已执行）：

```bash
FLUTTER=~/fvm/versions/3.47.2
cd $FLUTTER && git reset --hard HEAD
for p in modal_barrier text_selection mouse_cursor image_anim layout_builder \
  navigation_drawer popup_menu fab null_safety_for_selectable_region selectable_region \
  editable_text text_field scroll_position scrollable scrollable_gesture \
  draggable_scrollable_sheet scaffold text text_painter sliver refresh_indicator \
  bottom_sheet_android scroll_view navigator predictive_back_page_transitions_builder; do
  git apply /Users/Ray/Documents/Fork/PiliSync/lib/scripts/$p.patch
done

# material_ui 补丁（先重置 pub cache 保证干净）
rm -rf ~/.pub-cache/hosted/pub.dev/material_ui-1.1.0
fvm flutter pub get
MUI=$(ls -d ~/.pub-cache/hosted/pub.dev/material_ui-* | tail -1)
cd $MUI
for p in modal_barrier_material navigation_drawer popup_menu fab text_field \
  scaffold refresh_indicator tabs bottom_sheet_android; do
  git apply /Users/Ray/Documents/Fork/PiliSync/lib/scripts/material/$p.patch
done
```

验证：`fvm flutter analyze` 应无 error（79 个 info/warning 是上游固有基线）。

## 已知坑

1. **Android SDK Platform 37**：Gradle 自动安装的目录叫 `android-37.0`，且
   `source.properties` 写的是 `AndroidVersion.ApiLevel=37.0`，Gradle 找不到
   `android-37`。修法：目录改名 `android-37`，并把 ApiLevel 改成整数 `37`。
2. **flutter_tester 环境下 `web_socket_channel` 帧发不出去**（原因未查明，
   `dart:io` 原生 WebSocket 正常），所以 `wt_signaling_client.dart` 用
   `dart:io` WebSocket。真机上两者都行，但保持一致用 dart:io。
3. `dart:io` WebSocket：文本帧回调给 `String`，二进制帧才给 `List<int>`。
4. flutter_test 的 binding 会 mock HttpClient → 对时只能走 WS `tsync`。

## 一起看调试流程

```bash
# 1. 起信令服务器
cd signaling && go build -o signaling-server . && ./signaling-server

# 2. adb 反向代理，让真机的 127.0.0.1:9901 指到宿主机
adb reverse tcp:9901 tcp:9901

# 3. 真机 App：设置 → 一起看 → 服务器填 127.0.0.1:9901 → 建房/加入
```

双人测试：单设备可借助开发者模式（后续加）或第二台设备/模拟器。
