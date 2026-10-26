// ButtonMappingView.swift
// 按键页：照搬 Win 版 ButtonsPage.qml——中间是 Chromecast 实物图，左右两列是
// 映射卡片（单击 / 双击 / 长按三列），选中卡片时蓝色贝塞尔连线指向实物图上的按键，
// 底部是“检测真实按键”、“配置预设”和“恢复默认配置”。实物图来自社区 Win 版
// （Resources/Chromecast-remote-photo.png，GPL-3.0）；热点坐标是 2026-10-26 用程序
// 从实物图里抠每个按键的黑色轮廓实测的（v7 那套是肉眼估的，量错了，见 v9 记录）。

import SwiftUI
import AppKit

/// 映射选项（界面本地类型，不替代 Shared.swift 的 ButtonAction）。
private enum MappingChoice: Hashable, CaseIterable {
    case none
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case enter, escape
    case volumeUp, volumeDown, muteToggle
    case playPause, nextTrack, previousTrack
    case custom

    var displayName: String {
        switch self {
        case .none: return "无动作"
        case .arrowUp: return "方向键 ↑"
        case .arrowDown: return "方向键 ↓"
        case .arrowLeft: return "方向键 ←"
        case .arrowRight: return "方向键 →"
        case .enter: return "确认 ⏎"
        case .escape: return "返回 ⎋"
        case .volumeUp: return "音量+"
        case .volumeDown: return "音量-"
        case .muteToggle: return "静音切换"
        case .playPause: return "播放/暂停"
        case .nextTrack: return "下一曲"
        case .previousTrack: return "上一曲"
        case .custom: return "自定义组合键…"
        }
    }

    var action: ButtonAction {
        switch self {
        case .none: return .none
        case .arrowUp: return .key(.upArrow)
        case .arrowDown: return .key(.downArrow)
        case .arrowLeft: return .key(.leftArrow)
        case .arrowRight: return .key(.rightArrow)
        case .enter: return .key(.enter)
        case .escape: return .key(.escape)
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .muteToggle: return .muteToggle
        case .playPause: return .playPause
        case .nextTrack: return .nextTrack
        case .previousTrack: return .previousTrack
        case .custom: return .none
        }
    }

    static func from(_ action: ButtonAction) -> MappingChoice {
        switch action {
        case .none: return .none
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .muteToggle: return .muteToggle
        case .playPause: return .playPause
        case .nextTrack: return .nextTrack
        case .previousTrack: return .previousTrack
        case .key(let combo):
            if combo == .upArrow { return .arrowUp }
            if combo == .downArrow { return .arrowDown }
            if combo == .leftArrow { return .arrowLeft }
            if combo == .rightArrow { return .arrowRight }
            if combo == .enter { return .enter }
            if combo == .escape { return .escape }
            return .custom
        }
    }
}

/// 实物图上的热点：相对照片宽高的分数（Win 版 remote_layout.py 原值）。
private struct Hotspot {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
}

struct ButtonMappingView: View {
    @EnvironmentObject private var engine: MicEngine
    var onOpenVoice: () -> Void = {}

    @State private var selectedButton: RemoteButton = .select
    @State private var detecting = false
    @State private var hoveredButton: RemoteButton? = nil
    @State private var showResetConfirm = false
    /// 正在录入的格子（非空时弹出录入框）。
    @State private var captureTarget: CaptureTarget? = nil
    /// 保存预设的输入框状态。
    @State private var showingPresetSave = false
    @State private var presetName = ""

    /// 左列 7 张卡（行 0…6）。
    private let leftButtons: [RemoteButton] = [.up, .left, .down, .back, .home, .youtube, .power]

    /// 热点：相对照片宽高的分数，中心点 + 宽高。2026-10-26 用程序从实物图里抠
    /// 每个按键的黑色轮廓实测（连通域分析），不再凭肉眼估、也不再照搬 Win 版原值：
    /// 圆按键取轮廓外接圆再内收 2%（蓝圈正好贴着按键边缘），方向盘四段取外圈与
    /// 确认键之间的环带弧段，音量键取右侧边露出的拨杆凸起。
    private let hotspots: [RemoteButton: Hotspot] = [
        .up: Hotspot(x: 0.497, y: 0.063, w: 0.362, h: 0.085),
        .left: Hotspot(x: 0.196, y: 0.158, w: 0.269, h: 0.107),
        .select: Hotspot(x: 0.494, y: 0.157, w: 0.322, h: 0.102),
        .right: Hotspot(x: 0.795, y: 0.158, w: 0.274, h: 0.107),
        .down: Hotspot(x: 0.497, y: 0.252, w: 0.362, h: 0.086),
        .back: Hotspot(x: 0.249, y: 0.358, w: 0.309, h: 0.097),
        .home: Hotspot(x: 0.248, y: 0.486, w: 0.307, h: 0.097),
        .mute: Hotspot(x: 0.728, y: 0.487, w: 0.309, h: 0.097),
        .youtube: Hotspot(x: 0.248, y: 0.613, w: 0.307, h: 0.096),
        .netflix: Hotspot(x: 0.725, y: 0.613, w: 0.307, h: 0.096),
        .power: Hotspot(x: 0.247, y: 0.734, w: 0.175, h: 0.056),
        .input: Hotspot(x: 0.727, y: 0.734, w: 0.173, h: 0.056),
        .volumeUp: Hotspot(x: 0.985, y: 0.218, w: 0.05, h: 0.035),
        .volumeDown: Hotspot(x: 0.985, y: 0.246, w: 0.05, h: 0.035),
    ]
    /// 话筒键热点（语音导航卡的连线落点）。
    private let micHotspot = Hotspot(x: 0.733, y: 0.359, w: 0.296, h: 0.093)

    private static let commonCombos: [KeyCombo] = [
        .fn, .enter, .escape, .upArrow, .downArrow, .leftArrow, .rightArrow,
        .deleteBackward, .missionControl, .appWindows, .spaceLeft, .spaceRight, .inputSource, .appSwitcher,
        KeyCombo(keyCode: 8, modifiers: 1 << 20, isFn: false, display: "⌘C"),
        KeyCombo(keyCode: 9, modifiers: 1 << 20, isFn: false, display: "⌘V"),
        KeyCombo(keyCode: 7, modifiers: 1 << 20, isFn: false, display: "⌘X"),
        KeyCombo(keyCode: 6, modifiers: 1 << 20, isFn: false, display: "⌘Z"),
        KeyCombo(keyCode: 0, modifiers: 1 << 20, isFn: false, display: "⌘A"),
        // 常用组合（SayAll 选择器同款维度）：保存、关闭、退出、查找、聚焦搜索、重做、刷新、新建标签页。
        KeyCombo(keyCode: 1, modifiers: 1 << 20, isFn: false, display: "⌘S"),
        KeyCombo(keyCode: 13, modifiers: 1 << 20, isFn: false, display: "⌘W"),
        KeyCombo(keyCode: 12, modifiers: 1 << 20, isFn: false, display: "⌘Q"),
        KeyCombo(keyCode: 3, modifiers: 1 << 20, isFn: false, display: "⌘F"),
        KeyCombo(keyCode: 49, modifiers: 1 << 20, isFn: false, display: "⌘空格"),
        KeyCombo(keyCode: 6, modifiers: (1 << 20) | (1 << 17), isFn: false, display: "⌘⇧Z"),
        KeyCombo(keyCode: 15, modifiers: 1 << 20, isFn: false, display: "⌘R"),
        KeyCombo(keyCode: 17, modifiers: 1 << 20, isFn: false, display: "⌘T"),
    ]

    /// 功能键 F1–F20（macOS 标准 keyCode）。
    private static let functionKeys: [KeyCombo] = [
        KeyCombo(keyCode: 122, modifiers: 0, isFn: false, display: "F1"),
        KeyCombo(keyCode: 120, modifiers: 0, isFn: false, display: "F2"),
        KeyCombo(keyCode: 99, modifiers: 0, isFn: false, display: "F3"),
        KeyCombo(keyCode: 118, modifiers: 0, isFn: false, display: "F4"),
        KeyCombo(keyCode: 96, modifiers: 0, isFn: false, display: "F5"),
        KeyCombo(keyCode: 97, modifiers: 0, isFn: false, display: "F6"),
        KeyCombo(keyCode: 98, modifiers: 0, isFn: false, display: "F7"),
        KeyCombo(keyCode: 100, modifiers: 0, isFn: false, display: "F8"),
        KeyCombo(keyCode: 101, modifiers: 0, isFn: false, display: "F9"),
        KeyCombo(keyCode: 109, modifiers: 0, isFn: false, display: "F10"),
        KeyCombo(keyCode: 103, modifiers: 0, isFn: false, display: "F11"),
        KeyCombo(keyCode: 111, modifiers: 0, isFn: false, display: "F12"),
        KeyCombo(keyCode: 105, modifiers: 0, isFn: false, display: "F13"),
        KeyCombo(keyCode: 107, modifiers: 0, isFn: false, display: "F14"),
        KeyCombo(keyCode: 113, modifiers: 0, isFn: false, display: "F15"),
        KeyCombo(keyCode: 106, modifiers: 0, isFn: false, display: "F16"),
        KeyCombo(keyCode: 64, modifiers: 0, isFn: false, display: "F17"),
        KeyCombo(keyCode: 79, modifiers: 0, isFn: false, display: "F18"),
        KeyCombo(keyCode: 80, modifiers: 0, isFn: false, display: "F19"),
        KeyCombo(keyCode: 90, modifiers: 0, isFn: false, display: "F20"),
    ]

    /// 导航键：Home、End、PageUp、PageDown、前向删除。
    private static let navigationKeys: [KeyCombo] = [
        KeyCombo(keyCode: 115, modifiers: 0, isFn: false, display: "Home"),
        KeyCombo(keyCode: 119, modifiers: 0, isFn: false, display: "End"),
        KeyCombo(keyCode: 116, modifiers: 0, isFn: false, display: "⇞"),
        KeyCombo(keyCode: 121, modifiers: 0, isFn: false, display: "⇟"),
        KeyCombo(keyCode: 117, modifiers: 0, isFn: false, display: "⌦"),
    ]

    /// 数字键盘：数字、运算符号、回车、等号、清除。
    private static let numpadKeys: [KeyCombo] = [
        KeyCombo(keyCode: 82, modifiers: 0, isFn: false, display: "数字键盘 0"),
        KeyCombo(keyCode: 83, modifiers: 0, isFn: false, display: "数字键盘 1"),
        KeyCombo(keyCode: 84, modifiers: 0, isFn: false, display: "数字键盘 2"),
        KeyCombo(keyCode: 85, modifiers: 0, isFn: false, display: "数字键盘 3"),
        KeyCombo(keyCode: 86, modifiers: 0, isFn: false, display: "数字键盘 4"),
        KeyCombo(keyCode: 87, modifiers: 0, isFn: false, display: "数字键盘 5"),
        KeyCombo(keyCode: 88, modifiers: 0, isFn: false, display: "数字键盘 6"),
        KeyCombo(keyCode: 89, modifiers: 0, isFn: false, display: "数字键盘 7"),
        KeyCombo(keyCode: 91, modifiers: 0, isFn: false, display: "数字键盘 8"),
        KeyCombo(keyCode: 92, modifiers: 0, isFn: false, display: "数字键盘 9"),
        KeyCombo(keyCode: 65, modifiers: 0, isFn: false, display: "数字键盘 ."),
        KeyCombo(keyCode: 69, modifiers: 0, isFn: false, display: "数字键盘 +"),
        KeyCombo(keyCode: 78, modifiers: 0, isFn: false, display: "数字键盘 −"),
        KeyCombo(keyCode: 67, modifiers: 0, isFn: false, display: "数字键盘 ×"),
        KeyCombo(keyCode: 75, modifiers: 0, isFn: false, display: "数字键盘 ÷"),
        KeyCombo(keyCode: 76, modifiers: 0, isFn: false, display: "数字键盘 ⏎"),
        KeyCombo(keyCode: 81, modifiers: 0, isFn: false, display: "数字键盘 ="),
        KeyCombo(keyCode: 71, modifiers: 0, isFn: false, display: "数字键盘 Clear"),
    ]

    /// 单独的左右修饰键（SayAll 选择器同款维度；CGEvent 会把修饰键码当作 flagsChanged 发出）。
    private static let standaloneModifiers: [KeyCombo] = [
        KeyCombo(keyCode: 55, modifiers: 0, isFn: false, display: "左⌘"),
        KeyCombo(keyCode: 54, modifiers: 0, isFn: false, display: "右⌘"),
        KeyCombo(keyCode: 58, modifiers: 0, isFn: false, display: "左⌥"),
        KeyCombo(keyCode: 61, modifiers: 0, isFn: false, display: "右⌥"),
        KeyCombo(keyCode: 59, modifiers: 0, isFn: false, display: "左⌃"),
        KeyCombo(keyCode: 62, modifiers: 0, isFn: false, display: "右⌃"),
        KeyCombo(keyCode: 56, modifiers: 0, isFn: false, display: "左⇧"),
        KeyCombo(keyCode: 60, modifiers: 0, isFn: false, display: "右⇧"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部设备切换条（Win 版 mappingViewSwitcher 同款，Mac 只有一台设备）
            HStack(spacing: 10) {
                Text("Chromecast Remote")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Theme.accent)
                    .cornerRadius(Theme.controlRadius)
                Text(engine.connectionState.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(10)

            // 中间映射板
            GeometryReader { geo in board(geo: geo) }

            // 底部操作条（Win 版 mappingActionsPanel 同款）
            HStack(spacing: 8) {
                // 注意：Swift 三元表达式要求两分支同类型，两种 ButtonStyle 不能写在一个 ?: 里，
                // 所以这里用 if/else 分开写两个按钮。
                if detecting {
                    Button("停止检测") { detecting.toggle() }
                        .buttonStyle(ThemePrimaryButtonStyle())
                } else {
                    Button("检测真实按键") { detecting.toggle() }
                        .buttonStyle(ThemeSecondaryButtonStyle())
                }
                Text(detectHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                // 配置预设（Win 版“管理按键配置”同款）：保存当前整套映射，点名应用。
                Menu("配置预设") {
                    Button("保存当前配置…") {
                        presetName = ""
                        showingPresetSave = true
                    }
                    if !engine.settings.presets.isEmpty {
                        Divider()
                        ForEach(engine.settings.presets.keys.sorted(), id: \.self) { name in
                            Button(name) { engine.applyPreset(name: name) }
                        }
                        Divider()
                        Menu("删除预设") {
                            ForEach(engine.settings.presets.keys.sorted(), id: \.self) { name in
                                Button(name, role: .destructive) { engine.deletePreset(name: name) }
                            }
                        }
                    }
                }
                Button("恢复默认配置") { showResetConfirm = true }
                    .buttonStyle(ThemeSecondaryButtonStyle())
            }
            .padding(10)
        }
        .onChange(of: engine.lastPressedButton) { _, pressed in
            if detecting, let pressed {
                selectedButton = pressed
            }
        }
        .confirmationDialog(
            "恢复内置默认？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) { resetToDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会把全部按键恢复为内置默认映射，并立即保存。")
        }
        .sheet(isPresented: $showingPresetSave) {
            VStack(spacing: 12) {
                Text("保存按键配置预设").font(.headline)
                TextField("预设名称", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                HStack(spacing: 8) {
                    Button("取消") { showingPresetSave = false }
                    Button("保存") {
                        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            engine.savePreset(name: name)
                            showingPresetSave = false
                        }
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 320)
        }
        .sheet(item: $captureTarget) { target in
            ShortcutCaptureView { combo in
                engine.setMapping(button: target.button, press: target.press, action: .key(combo))
                captureTarget = nil
            } onCancel: {
                captureTarget = nil
            }
        }
    }

    private var detectHint: String {
        if detecting {
            if let pressed = engine.lastPressedButton {
                return "已检测到：\(pressed.displayName) 键"
            }
            return "按一下遥控器上的键，对应卡片会高亮"
        }
        return "开始检测后，按一下遥控器上的键"
    }

    // MARK: - 映射板几何

    private struct BoardGeom {
        var width: CGFloat
        var height: CGFloat
        var cardH: CGFloat
        var gap: CGFloat
        var boardH: CGFloat
        var boardTop: CGFloat
        var photoW: CGFloat
        var photoH: CGFloat
        var photoX: CGFloat
        var photoY: CGFloat
        var colW: CGFloat

        func rowCenterY(_ row: Int) -> CGFloat {
            boardTop + CGFloat(row) * (cardH + gap) + cardH / 2
        }
    }

    private func board(geo: GeometryProxy) -> some View {
        let cardH: CGFloat = 49
        let gap: CGFloat = 2
        let rows = 8
        let boardH = CGFloat(rows) * cardH + CGFloat(rows - 1) * gap
        let photoH = min(max(geo.size.height - 16, 200), 430)
        let photoW = photoH * 453 / 1443
        let photoColW = photoW + 44
        let colW = max(200, (geo.size.width - photoColW - 12) / 2)
        let g = BoardGeom(
            width: geo.size.width,
            height: geo.size.height,
            cardH: cardH,
            gap: gap,
            boardH: boardH,
            boardTop: max(0, (geo.size.height - boardH) / 2),
            photoW: photoW,
            photoH: photoH,
            photoX: (geo.size.width - photoW) / 2,
            photoY: (geo.size.height - photoH) / 2,
            colW: colW
        )
        return ZStack {
            // 1. 非选中连线（灰）
            ForEach(connectorRows) { row in
                if row.button != selectedButton {
                    connectorPath(row: row, geom: g)
                        .stroke(Theme.borderStrong, lineWidth: 1.25)
                }
            }
            // 2. 实物图
            remotePhoto(width: g.photoW, height: g.photoH)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .shadow(color: Color.black.opacity(0.4), radius: 5, x: 0, y: 2)
            // 3. 选中连线（蓝）
            ForEach(connectorRows) { row in
                if row.button == selectedButton {
                    connectorPath(row: row, geom: g)
                        .stroke(Theme.accent, lineWidth: 2.2)
                }
            }
            // 4. 热点点击区（透明，覆盖整颗按键）
            ForEach(hotspotButtons) { item in
                hotspotTapArea(item: item, geom: g)
            }
            // 5. 热点标记（选中 / 悬停时显示）
            ForEach(hotspotButtons) { item in
                hotspotMarker(item: item, geom: g)
            }
            // 6. 卡片列
            leftColumn(width: g.colW, geom: g)
                .position(x: g.colW / 2, y: g.boardTop + g.boardH / 2)
            rightColumn(width: g.colW, geom: g)
                .position(x: geo.size.width - g.colW / 2, y: g.boardTop + g.boardH / 2)
        }
    }

    // MARK: - 连线

    private struct ConnectorRow: Identifiable {
        var id: String
        var row: Int
        var isLeft: Bool
        var button: RemoteButton?
        var hotspot: Hotspot
    }

    private var connectorRows: [ConnectorRow] {
        var rows: [ConnectorRow] = []
        for (index, button) in leftButtons.enumerated() {
            if let hs = hotspots[button] {
                rows.append(ConnectorRow(id: button.rawValue, row: index, isLeft: true, button: button, hotspot: displayHotspot(hs, for: button)))
            }
        }
        let rightOrder: [(Int, RemoteButton?)] = [
            (0, .select), (1, .right), (2, .volumeUp), (3, .volumeDown),
            (4, nil), (5, .mute), (6, .netflix), (7, .input),
        ]
        for (row, button) in rightOrder {
            if let button, let hs = hotspots[button] {
                rows.append(ConnectorRow(id: button.rawValue, row: row, isLeft: false, button: button, hotspot: displayHotspot(hs, for: button)))
            } else if button == nil {
                rows.append(ConnectorRow(id: "voice", row: row, isLeft: false, button: nil, hotspot: micHotspot))
            }
        }
        return rows
    }

    /// 显示用热点：方向盘四段在点按区基础上向内收一圈，画出来是落在环带上的小 pill，
    /// 而不是铺满整个扇区的大椭圆；点按区仍用原尺寸（好点）。圆按键与音量键不收。
    private func displayHotspot(_ hs: Hotspot, for button: RemoteButton?) -> Hotspot {
        guard let button, [.up, .down, .left, .right].contains(button) else { return hs }
        return Hotspot(x: hs.x, y: hs.y, w: hs.w * 0.72, h: hs.h * 0.68)
    }

    /// Win 版 connectorRoute 原样：起点卡片边缘，终点热点边缘（确认键取圆顶），
    /// 两端水平切线的三次贝塞尔。
    private func connectorPath(row: ConnectorRow, geom: BoardGeom) -> Path {
        let hs = row.hotspot
        let centerX = geom.photoX + hs.x * geom.photoW
        let centerY = geom.photoY + hs.y * geom.photoH
        let halfW = hs.w * geom.photoW / 2
        let halfH = hs.h * geom.photoH / 2
        let isOK = (row.button == .select)
        let endX = isOK ? centerX : centerX + (row.isLeft ? -1 : 1) * halfW
        let endY = isOK ? centerY - halfH : centerY
        let startX = row.isLeft ? geom.colW : geom.width - geom.colW
        let startY = geom.rowCenterY(row.row)
        let span = abs(endX - startX)
        let controlRadius = min(max(12, min(72, span * 0.56)), span * 0.48)
        let direction: CGFloat = row.isLeft ? 1 : -1
        let c1 = CGPoint(x: startX + direction * controlRadius, y: startY)
        let c2 = CGPoint(x: endX - direction * controlRadius, y: endY)
        var path = Path()
        path.move(to: CGPoint(x: startX, y: startY))
        path.addCurve(to: CGPoint(x: endX, y: endY), control1: c1, control2: c2)
        return path
    }

    // MARK: - 实物图与热点

    private var remotePhotoImage: NSImage? {
        guard let url = Bundle.module.url(forResource: "Chromecast-remote-photo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }

    private func remotePhoto(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let image = remotePhotoImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            } else {
                RoundedRectangle(cornerRadius: 40)
                    .fill(Theme.surfaceMuted)
                    .frame(width: width, height: height)
                    .overlay(
                        Text("实物图缺失")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    )
            }
        }
    }

    private struct HotspotButton: Identifiable {
        var id: String
        var button: RemoteButton?
        var hotspot: Hotspot
    }

    private var hotspotButtons: [HotspotButton] {
        var items: [HotspotButton] = []
        for button in RemoteButton.allCases {
            if let hs = hotspots[button] {
                items.append(HotspotButton(id: button.rawValue, button: button, hotspot: hs))
            }
        }
        items.append(HotspotButton(id: "voice", button: nil, hotspot: micHotspot))
        return items
    }

    private func hotspotRect(item: HotspotButton, geom: BoardGeom) -> CGRect {
        let hs = item.hotspot
        return CGRect(
            x: geom.photoX + (hs.x - hs.w / 2) * geom.photoW,
            y: geom.photoY + (hs.y - hs.h / 2) * geom.photoH,
            width: hs.w * geom.photoW,
            height: hs.h * geom.photoH
        )
    }

    private func hotspotTapArea(item: HotspotButton, geom: BoardGeom) -> some View {
        let rect = hotspotRect(item: item, geom: geom)
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .onTapGesture {
                if let button = item.button {
                    selectedButton = button
                } else {
                    onOpenVoice()
                }
            }
            .onHover { hovering in
                if hovering {
                    hoveredButton = item.button
                } else if hoveredButton == item.button {
                    hoveredButton = nil
                }
            }
    }

    private func hotspotMarker(item: HotspotButton, geom: BoardGeom) -> some View {
        // 标记用显示热点（方向盘四段是收过的 pill），点按区仍用原尺寸。
        let display = displayHotspot(item.hotspot, for: item.button)
        let rect = CGRect(
            x: geom.photoX + (display.x - display.w / 2) * geom.photoW,
            y: geom.photoY + (display.y - display.h / 2) * geom.photoH,
            width: display.w * geom.photoW,
            height: display.h * geom.photoH
        )
        // 蓝圈只表示“选中”，唯一一个。悬停不再画圈（否则图上同时出现两个蓝圈，
        // 看起来像选中了两个），悬停反馈只给卡片一层浅灰底。
        let isSelected = (item.button != nil && item.button == selectedButton)
        guard isSelected else {
            return AnyView(EmptyView())
        }
        // 圆按键画椭圆，正好贴合按键边缘；方向盘弧段画椭圆高亮，也比圆角矩形贴合。
        return AnyView(
            Ellipse()
                .fill(Theme.accent.opacity(0.20))
                .overlay(
                    Ellipse()
                        .stroke(Theme.accent, lineWidth: 2)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        )
    }

    // MARK: - 卡片列

    private func leftColumn(width: CGFloat, geom: BoardGeom) -> some View {
        VStack(spacing: geom.gap) {
            ForEach(0..<8) { row in
                if row < leftButtons.count {
                    mappingCard(button: leftButtons[row], width: width)
                } else {
                    Color.clear.frame(width: width, height: geom.cardH)
                }
            }
        }
    }

    private func rightColumn(width: CGFloat, geom: BoardGeom) -> some View {
        VStack(spacing: geom.gap) {
            mappingCard(button: .select, width: width)
            mappingCard(button: .right, width: width)
            mappingCard(button: .volumeUp, width: width)
            mappingCard(button: .volumeDown, width: width)
            voiceCard(width: width)
            mappingCard(button: .mute, width: width)
            mappingCard(button: .netflix, width: width)
            mappingCard(button: .input, width: width)
        }
    }

    private func mappingCard(button: RemoteButton, width: CGFloat) -> some View {
        ThemeCard(selected: selectedButton == button,
                  hovered: hoveredButton == button && selectedButton != button) {
            HStack(spacing: 0) {
                Text(button.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 56)
                ForEach(PressKind.allCases, id: \.self) { press in
                    gestureCell(button: button, press: press)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .frame(width: width, height: 49)
        .contentShape(Rectangle())
        .onTapGesture { selectedButton = button }
        .onHover { hovering in
            if hovering {
                hoveredButton = button
            } else if hoveredButton == button {
                hoveredButton = nil
            }
        }
    }

    /// 语音导航卡：单击格显示当前语音模式，点卡片跳到语音页。
    private func voiceCard(width: CGFloat) -> some View {
        ThemeCard(selected: false) {
            HStack(spacing: 0) {
                Text("语音")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 56)
                VStack(spacing: 0) {
                    Text("单击")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(height: 13)
                    Text(engine.settings.voiceMode.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(height: 22)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surfaceMuted)
                        .cornerRadius(3)
                }
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 0.5)
                VStack(spacing: 0) {
                    Text("双击 / 长按")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.disabledText)
                        .frame(height: 13)
                    Text("—")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.disabledText)
                        .frame(height: 22)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .frame(width: width, height: 49)
        .contentShape(Rectangle())
        .onTapGesture { onOpenVoice() }
    }

    // MARK: - 动作格（Win 版 GestureCell 同款：上行是单击 / 双击 / 长按，
    // 下行是已配置的动作值，直接显示在页面上）
    //
    // 注意：动作值不能放在 Menu 的 label 里——macOS 的 borderlessButton 样式下，
    // Menu label 里的多行内容只显示第一行（之前“单击”下面那行动作值就是这么丢的）。
    // 所以格子改成两层：下层是普通文本（一定能显示），上层盖一个透明 label 的 Menu
    //（点格子任何位置都弹出选项，样式自带的小箭头还在）。

    private func gestureCell(button: RemoteButton, press: PressKind) -> some View {
        let key = AppSettings.mappingKey(button: button, press: press)
        let action = engine.settings.mappings[key] ?? .none
        return HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 0.5)
            ZStack {
                VStack(spacing: 0) {
                    Text(press.displayName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(height: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(cardText(action))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(action == .none ? Theme.disabledText : Theme.textPrimary)
                        .frame(height: 22)
                        .frame(maxWidth: .infinity)
                        .background(action == .none ? Color.clear : Theme.surfaceMuted)
                        .cornerRadius(3)
                }
                .padding(.horizontal, 3)
                Menu {
                    ForEach(MappingChoice.allCases, id: \.self) { choice in
                        if choice == .custom {
                            Menu(choice.displayName) {
                                ForEach(Self.commonCombos, id: \.display) { combo in
                                    Button(combo.display) {
                                        engine.setMapping(button: button, press: press, action: .key(combo))
                                    }
                                }
                                Divider()
                                Menu("功能键 F1–F20") {
                                    ForEach(Self.functionKeys, id: \.display) { combo in
                                        Button(combo.display) {
                                            engine.setMapping(button: button, press: press, action: .key(combo))
                                        }
                                    }
                                }
                                Menu("导航键") {
                                    ForEach(Self.navigationKeys, id: \.display) { combo in
                                        Button(combo.display) {
                                            engine.setMapping(button: button, press: press, action: .key(combo))
                                        }
                                    }
                                }
                                Menu("数字键盘") {
                                    ForEach(Self.numpadKeys, id: \.display) { combo in
                                        Button(combo.display) {
                                            engine.setMapping(button: button, press: press, action: .key(combo))
                                        }
                                    }
                                }
                                Menu("修饰键（单独）") {
                                    ForEach(Self.standaloneModifiers, id: \.display) { combo in
                                        Button(combo.display) {
                                            engine.setMapping(button: button, press: press, action: .key(combo))
                                        }
                                    }
                                }
                            }
                        } else {
                            Button(choice.displayName) {
                                engine.setMapping(button: button, press: press, action: choice.action)
                            }
                        }
                    }
                    Divider()
                    // Win 版录入同款：按一下就录，不用在菜单里挑。
                    Button("录入…") {
                        captureTarget = CaptureTarget(button: button, press: press)
                    }
                } label: {
                    Color.clear
                }
                .menuStyle(.borderlessButton)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    /// 卡片里的动作短文本（Win 版 displayBinding 同款：Enter / Esc / Vol + / 未设置）。
    private func cardText(_ action: ButtonAction) -> String {
        switch action {
        case .none: return "未设置"
        case .volumeUp: return "Vol +"
        case .volumeDown: return "Vol -"
        case .muteToggle: return "系统静音"
        case .playPause: return "播放/暂停"
        case .nextTrack: return "下一曲"
        case .previousTrack: return "上一曲"
        case .key(let combo):
            switch combo.display {
            case "⏎": return "Enter"
            case "⎋": return "Esc"
            case "⌫": return "Del"
            default: return combo.display
            }
        }
    }

    /// 恢复默认映射：逐项写回 AppSettings.defaultMappings，未列出的按无动作。
    private func resetToDefaults() {
        for button in RemoteButton.allCases {
            for press in PressKind.allCases {
                let key = AppSettings.mappingKey(button: button, press: press)
                engine.setMapping(button: button, press: press, action: AppSettings.defaultMappings[key] ?? .none)
            }
        }
    }
}

/// 录入框的目标格子（sheet 的 item）。
private struct CaptureTarget: Identifiable {
    var button: RemoteButton
    var press: PressKind
    var id: String { button.rawValue + "#" + press.rawValue }
}

/// 快捷键录入框（Win 版录入同款）：弹出后按一下组合键即录入，Esc 取消。
/// 用 NSEvent 本地监听：keyDown 取键码 + 修饰键，flagsChanged 只认 Fn（keyCode 63）。
private struct ShortcutCaptureView: View {
    var onCaptured: (KeyCombo) -> Void
    var onCancel: () -> Void

    @State private var monitors: [Any] = []

    var body: some View {
        VStack(spacing: 12) {
            Text("录入快捷键").font(.headline)
            Text("请按下要发送的组合键（按 Esc 取消）")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Button("取消") { onCancel() }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { installMonitors() }
        .onDisappear { removeMonitors() }
    }

    private func installMonitors() {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 裸 Esc = 取消，不录成映射（Win 版录入框同款行为）。
            if event.keyCode == 53
                && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                onCancel()
                return nil
            }
            let modifiers = Int(event.modifierFlags
                .intersection([.command, .control, .option, .shift]).rawValue)
            let combo = KeyCombo(
                keyCode: Int(event.keyCode),
                modifiers: modifiers,
                isFn: false,
                display: Self.displayFor(event: event)
            )
            onCaptured(combo)
            return nil
        } {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if event.keyCode == 63 {
                onCaptured(.fn)
                return nil
            }
            return event
        } {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    /// 按键显示文本：修饰键字形（⌃⌥⇧⌘）+ 键名；方向键、功能键、空格等有固定写法。
    private static func displayFor(event: NSEvent) -> String {
        var glyphs = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { glyphs += "⌃" }
        if flags.contains(.option) { glyphs += "⌥" }
        if flags.contains(.shift) { glyphs += "⇧" }
        if flags.contains(.command) { glyphs += "⌘" }
        let keyPart: String
        switch Int(event.keyCode) {
        case 123: keyPart = "←"
        case 124: keyPart = "→"
        case 125: keyPart = "↓"
        case 126: keyPart = "↑"
        case 36: keyPart = "⏎"
        case 53: keyPart = "⎋"
        case 49: keyPart = "空格"
        case 48: keyPart = "⇥"
        case 51: keyPart = "⌫"
        case 117: keyPart = "⌦"
        case 115: keyPart = "Home"
        case 119: keyPart = "End"
        case 116: keyPart = "⇞"
        case 121: keyPart = "⇟"
        case 76: keyPart = "数字键盘 ⏎"
        case 122: keyPart = "F1"
        case 120: keyPart = "F2"
        case 99: keyPart = "F3"
        case 118: keyPart = "F4"
        case 96: keyPart = "F5"
        case 97: keyPart = "F6"
        case 98: keyPart = "F7"
        case 100: keyPart = "F8"
        case 101: keyPart = "F9"
        case 109: keyPart = "F10"
        case 103: keyPart = "F11"
        case 111: keyPart = "F12"
        case 105: keyPart = "F13"
        case 107: keyPart = "F14"
        case 113: keyPart = "F15"
        case 106: keyPart = "F16"
        case 64: keyPart = "F17"
        case 79: keyPart = "F18"
        case 80: keyPart = "F19"
        case 90: keyPart = "F20"
        default: keyPart = (event.charactersIgnoringModifiers ?? "").uppercased()
        }
        return glyphs + keyPart
    }
}
