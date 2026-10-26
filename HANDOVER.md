# 交接文档：无线麦 Mac 版（Chromecast 遥控器当 Mac 麦克风）

> 代码版本：v17（本文件随代码一起打包，代码本身与 v17 完全一致，只多了本文档）。
> 交接原因：切换桌面（调度中心）快捷键模拟在该 Mac 上走不通，详见第 5 节。
> 阅读对象：接手继续开发的人。请先读完第 5、6 节再动手，避免重复踩已经证实走不通的路。

## 1. 项目是什么

把 Chromecast 语音遥控器（G9N9N）变成 Mac 的无线麦克风与遥控器：

- 语音：遥控器话筒键 → BLE + ATVV 协议收 16kHz 音频 → 经 BlackHole 虚拟麦克风送进输入法（当前用户用微信输入法 + Fn 热键）。
- 按键：遥控器方向、确认、返回、主页、电源、音量等 → 映射成键盘组合键 / 系统音量 / 播放控制，支持单击 / 双击 / 长按。
- 对标社区 Windows 版（ZSTDJan/windows-remote-mic-app，GPL-3.0），界面参考它的 QML 与实物图布局；本项目同样 GPL-3.0。

## 2. 代码与构建

- **完整工程**：本压缩包即全量代码（每次交付都是完整工程，不是补丁）。解压后在工程根目录执行：

  ```sh
  zsh packaging/build.sh
  ```

- 环境：macOS 14+，只需要 `/usr/bin/swift`（命令行工具），**不需要 Xcode.app**。
- 产物都在 `dist/`：`WirelessMic.app`、`.dmg`、`.zip`。构建脚本默认自动安装到固定路径 `/Applications/WirelessMic.app`（运行中则跳过并提示退出后重跑；`WIRELESSMIC_NO_INSTALL=1` 可跳过）。
- **版本确认**：工程根 `VERSION` 文件 + 构建脚本开头打印“工程版本：vX”。**务必先删旧文件夹再解压新包**（历史教训：同名 zip 反复覆盖会导致浏览器/解压端拿到缓存的旧包，用户用旧代码重复构建、报错一字不差）。
- 签名：`build.sh` 优先用钥匙串里的 `WirelessMic Local` 固定证书签名，没有则回落 ad-hoc。ad-hoc 每次构建签名都会变，系统会把每个新构建当成新应用，蓝牙 / 输入监控 / 辅助功能全部重新弹窗。固定证书做法：钥匙串访问 → 证书助理 → 创建证书（名 `WirelessMic Local`、自签名根证书、代码签名、有效期 3650 天）；签名时钥匙串弹窗点“始终允许”。换签名后第一次仍需授权一次（最后一次），首次启动 Gatekeeper 右键打开一次，之后构建都不用再授权。以后必须从 `/Applications` 启动，别从 Downloads 解压文件夹启动旧包。
- Bundle ID：`com.wirelessmic.mac`，非沙盒应用（需要 IOKit 读 HID 按键、CGEvent 模拟按键，所以不加沙盒 entitlements）。
- 虚拟麦克风需另装：BlackHole 2ch（官网下载，装完重启一次 Mac），应用内选 `BlackHole 2ch` 作为输出。
- 构建说明全文：`packaging/README-build.md`。

## 3. 架构（`Sources/WirelessMic/`）

| 文件 / 目录 | 职责 |
| --- | --- |
| `Shared.swift` | 共享类型：`RemoteButton`（按键，rawValue 与 SayAll 公开仓的 ChromecastRemoteControl 对齐）、`PressKind`（单击/双击/长按）、`KeyCombo`（keyCode + 修饰掩码 + 是否 Fn + 显示文本）、`ButtonAction`（无动作 / 按键 / 音量+ / 音量− / 静音切换 / 播放/暂停 / 上一曲 / 下一曲）、`VoiceMode`、`VoiceTool`。不要改类型名与 rawValue（映射持久化依赖）。 |
| `Core/ATVVEngine.swift` | BLE 连接 + ATVV 控制通道 + IMA/DVI ADPCM 解码。语音键不走 HID，走 ATVV。 |
| `Core/HIDMonitor.swift` | IOKit HID 监听：设备层回调 + **独占打开（seize）**，见第 4 节。按键边沿上报给 MappingEngine；未映射的用法只记原始日志。 |
| `Core/AudioPipeline.swift` | 音频输出：**必须用 HAL 单元（AUHAL）直连**选设备。教训：AVAudioEngine 的输出节点没有 `audioUnit` 属性（只有 `auAudioUnit`，且无法据此选设备），`engine.outputNode.audioUnit` 编译不过。 |
| `Core/KeySimulator.swift` | CGEvent 模拟按键（键盘、Fn 的 flagsChanged、系统媒体键）。调度中心问题见第 5 节。 |
| `Core/MappingEngine.swift` | 单击 / 双击 / 长按判定与执行，时序见第 4 节。 |
| `Core/SettingsStore.swift`、`Core/MicEngine.swift` | 设置持久化（`~/Library/Application Support/WirelessMic/settings.json`）与总引擎（连接、日志、动作执行回调）。启动日志第一行打印构建版本（`BuildVersion.string`，由 `build.sh` 在编译前把 `VERSION` 写进 `Sources/WirelessMic/GeneratedVersion.swift`）。 |
| `UI/` | `MainView`（左 48 宽图标导航 + 底部状态条）、`ButtonMappingView`（按键页：实物图 + 映射卡片 + 连线）、`DeviceView`（设备页 + 诊断日志）、`VoiceView`、`SettingsView`、`Theme.swift`、`PermissionGuide.swift`。 |
| `WirelessMicApp.swift` | `@main` + MenuBarExtra。 |
| `packaging/` | `build.sh`、`Info.plist`（含蓝牙 usage 描述）、`README-build.md`、`AppIcon.icns`（目前缺失，图标仍是系统默认）。 |
| `Resources/Chromecast-remote-photo.png` | 按键页实物图，来自社区 Win 版（GPL-3.0）。 |

## 4. 已证实可用的东西（不要推倒重来）

- **v0 全链路**：单文件 Swift 程序（用户 Mac 上 `chromecast-v0.swift`）已跑通，BLE + ATVV + 解码到 16kHz WAV 能听到人声。
- **连接与语音**：蓝牙名 `Chromecast Remote`，ATVV 握手实测 `CAPS version=0x0100 codecs=0x02 frameSize=160 sampleRate=16000`（16kHz）；话筒键按下 → 微信输入法 Fn 语音开始/结束，工作正常。
- **HID 独占**：日志出现 `HID 独占已建立（系统不再响应遥控器按键）` 即成功。独占后系统不再收到遥控器按键，拦住了确认键弹 Apple Music、电源键锁屏、静音键被系统再切一次等原生行为。独占失败时会回落共享模式并在日志明说（此时上述原生问题会复发，先查输入监控权限）。
- **HID 映射（实测值，不要凭感觉改）**：
  - 方向盘 = 消费页（0x0C）菜单键：`0x42` 上、`0x43` 下、`0x44` 左、`0x45` 右。
  - 返回 = `0x224` AC Back；音量+ `0xE9`、音量− `0xEA`、静音 `0xE2`。
  - 键盘页（0x07）：`0x52` 上、`0x51` 下、`0x50` 左、`0x4F` 右、`0x28` 回车、`0x29` ESC。
  - 每次按键还伴随一条 `usage 0xFFFFFFFF` 的厂商编码（值：上 3、下 4、左 5、右 6、返回 11），只记日志，**不要映射**（方向盘的 0x42–0x45 已足够）。
  - 候选（标准用法，已接进表，待日志验证）：`0x41` 菜单选择 = 确认、`0xCD` 播放/暂停 = 确认、`0x223` AC Home = 主页、`0x30` 电源 = 电源。同一颗键同时发两种用法时，按键级去重会合并成一次按下/抬起，不会变双击。
- **默认映射（v7 起）**：上 ↑ / 下 ↓ / 左 ← / 右 →、确定 Enter、返回 ⌫（keyCode 51，卡片显示 Del）、电源 Esc、主页 ⌃↑（Mission Control）、输入源 ⌃空格、音量±、静音；YouTube / Netflix 默认无动作，双击 / 长按全空。已存配置若与 v6 旧默认表完全一致，启动时自动升级为新表；改过的配置不动。
- **时序模型（v13，对齐 SayAll Mac 版公开文档）**：双击、长按都未设置时，单击按下即执行、按住重复（无修饰普通键与音量±：0.4 秒后每 0.1 秒一次；带修饰的组合键与静音开关只发一次，避免开关类反复触发）；只设长按时，按住 0.55 秒执行长按、提前抬起则抬起即执行单击；设双击时，抬起后等 0.3 秒窗口区分单击/双击；设了双击或长按的键不再按住重复。
- **组合键选择器（v14–v15，已补齐）**：每格菜单的“自定义组合键…”含常用组合（⌘C/V/X/Z/A/S/W/Q/F/空格/⇧Z/R/T、⌃↑/⌃↓/⌃←/⌃→、⌃空格、⌘Tab、Fn、方向键、⌫），以及功能键 F1–F20、导航键（Home/End/⇞/⇟/⌦）、数字键盘、单独的左右修饰键（左/右 ⌘⌥⌃⇧）四个子菜单；另有“录入…”（按一下就录，裸 Esc 取消，Fn 也能录）。播放控制（播放/暂停、上一曲、下一曲）走系统媒体键（NX_KEYTYPE 16/17/18），不按住重复。
- **诊断日志**：设备页有“复制日志”（整份进剪贴板，单行 Text 只能逐行选是 SwiftUI 限制）与“清空”按钮。关键行：`HID 独占已建立/失败`、`HID 原始：page/usage/value`、`动作：X 单击/双击/长按 → …`、`执行动作失败（…）`。
- **界面热点（v9 实测值，见 `ButtonMappingView.swift` 的 `hotspots`）**：用程序从实物图里抠每个按键的黑色轮廓实测（连通域分析：外圈 395×396、确认键 149×150、返回/主页/静音/YouTube/Netflix 约 142–143、话筒盘 137、电源/输入源约 81–82、右侧拨杆凸起在 y 295–375），再经 PIL 叠加验证图确认贴合后才写进代码。**教训：贴合类坐标绝不能凭肉眼从缩小图上估，也不能照搬 Win 版 `remote_layout.py` 的分数（Win 原值本身偏小、个别中心偏 0.01–0.015，在 Win 78px 小图上不明显，放到 Mac 大图上就是错位）。**

## 5. 已解决：调度中心快捷键模拟

**根因**：真实键盘的方向键事件自带 `maskSecondaryFn`（0x800000）标志，系统快捷键（⌃←/→/↑/↓）匹配时依赖它；合成事件缺这个标志就被当成普通按键（前台 App 发“噔”声）。此前试过的 HID 事件源、修饰键顺序都不是根因。

**修复（v18）**：`KeySimulator.mainKeyFlags` 对方向键与导航键自动补 `maskSecondaryFn`。已用测试程序实测：不带标志桌面不切换，带上后切换。

**调度中心里不能用方向键选窗口**：macOS 本身不支持（开“全键盘控制”也没用）。替代：⌘Tab 应用切换器会话（`MappingEngine.beginSwitcher`）——映射到 ⌘Tab 的动作会保持 ⌘ 按下并接管遥控器：左/右选择，上/下方向键，确定/主页确认，返回/电源取消，8 秒无操作自动确认。

**仍未解决：电源键锁屏**。电源键发消费页 `0x19E`（AL Terminal Lock），已加入 `keyTable`，但 `loginwindow` 仍会收到“TouchID pressed event”并锁屏，设备层独占拦不住；v18 改为 Manager 层独占，效果待验证。若仍锁屏，建议把电源键默认动作改为无动作。

**调试**：日志同步写入 `~/Library/Application Support/WirelessMic/app.log`。

## 6. 其他待办（按优先级）

1. **静音 / 主页 / 确定仍待日志确认**（v12–v13 时用户报过，之后未再收到针对性日志）：先看启动日志有无 `HID 独占已建立`，再分别按静音、主页、确定，把对应 `HID 原始` 行对照第 4 节映射表；独占未建立时系统原生行为会叠加（静音反复即此原因）。
2. **YouTube / Netflix / 输入源映射未知**：厂商自定义用法，`HIDMonitor` 目前只记原始日志不映射；拿到日志后按 page/usage 补 `keyTable`。
3. **HID 厂商自定义键与输入法语音热键默认值**：待真机验证。遥控器 VID 6353 / PID 37968；语音热键默认 Fn，若用户输入法快捷键不是 Fn，需改 `~/Library/Application Support/WirelessMic/settings.json` 的 `toolHotkeys` 或默认值。
4. **备注名功能未做**（Win 版有，留待后续）。
5. **应用图标仍是系统默认**（无 `AppIcon.png`，有图后跑 `zsh packaging/icon.sh` 再构建）。
6. **语音触发模式仍是按一次说话（toggle）**，未跟 Win 版改成按住型；是否改需与用户确认。
7. **历史构建教训**：Swift 三元表达式混用两种 ButtonStyle 编译不过（改 if/else 分开写）；macOS Menu label 在 borderlessButton 样式下多行只渲染第一行（动作值必须放下层普通文本，不能放 Menu label 里）；macOS Swift 交付前必须逐文件核 API 存在性（本机是 Linux VM、Mac 侧无 shell 入口，交出去的代码无法事先编译验证，绝不能让用户当编译器反复试错）。

## 7. 参考项目与用户环境

- **社区 Win 版**：`ZSTDJan/windows-remote-mic-app`（Python + QML，GPL-3.0，便携版 1.0.97，须整包解压后运行其中 exe）。含完整公开 ATVV 实现（服务 UUID `AB5E0001-5A21-4F05-BC7D-AF01F617B664`，TX `...0002`、AUDIO `...0003`、CTL `...0004`；操作码 AUDIO_STOP `0x00`、AUDIO_START `0x04`、MIC_BUTTON `0x08`、AUDIO_SYNC `0x0A`、CAPS `0x0B`；GET_CAPABILITIES_V10 = `0A 01 00 00 03 03`；MIC_OPEN = `0C 00`；音频 IMA/DVI ADPCM 16kHz，codec `0x02`，跨通知帧重组、DC 滤波与平滑增益）。界面 Tokens（浅灰底、白卡、`#087cf0` 蓝）与实物图布局亦参考它。
- **SayAll 官方**：`HD838A/remote-mic-app`（GPL-3.0）。公开 main 分支只有 Chromecast 集成层（状态枚举、按键驱动、能力契约、测试），真正设备驱动是私有包 SayAllChromecast（作者私有仓），公开拉取不到——“自己编译 SayAll”路线已证实走不通。Mac 版时序模型见其 README“自定义遥控器按键”一节（即第 4 节时序的来源）。官方正式版 v1.9.21 尚不支持 Chromecast；本地版是过渡方案，用户计划在官方支持 Chromecast 后改用官方版。
- **用户环境**：Apple Silicon MacBook Pro，macOS 15，arm64，系统语言英文（路径永远写英文）；遥控器 G9N9N（Chromecast Voice Remote，泰国产，FCC ID A4RG9N9N，蓝牙名 `Chromecast Remote`）。注意：Mac 侧没有可供 AI 使用的 shell/终端入口，构建、安装、运行都必须用户自己在终端执行；用户沟通用简体中文，短句、直接、结果导向。
