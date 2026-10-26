# 无线麦 Mac 版

把 Chromecast 语音遥控器（G9N9N）变成 Mac 的无线麦克风与遥控器：
蓝牙 ATVV 语音 + 按键映射 + 虚拟麦克风输出，配合输入法语音输入。

参考实现：社区 Win 版 ZSTDJan/windows-remote-mic-app 公开的 ATVV 协议
（IMA ADPCM 16kHz、MIC_OPEN、能力协商），GPL-3.0。

## 目录

- `Package.swift`：SwiftPM 工程（macOS 14+，无第三方依赖）。
- `Sources/WirelessMic/Shared.swift`：共享类型（引擎与界面共用，勿改名）。
- `Sources/WirelessMic/Core/`：引擎（ATVV、HID、音频、按键模拟、映射、设置）。
- `Sources/WirelessMic/UI/`：界面（设备/按键/语音/设置页、遥控器图、菜单栏）。
- `Sources/WirelessMic/WirelessMicApp.swift`：应用入口。
- `packaging/`：打包脚本与说明。

## 构建（在 Mac 上）

见 `packaging/README-build.md`，一句话：`zsh packaging/build.sh`，产物在 `dist/`。
