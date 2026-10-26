#!/bin/zsh
# 无线麦图标管线（可选步骤）
#
# 流程：
#   packaging/AppIcon.png（1024x1024，用户自备）
#     → sips 生成 10 张尺寸 → packaging/AppIcon.iconset/（中间产物，做完删除）
#     → iconutil -c icns → packaging/AppIcon.icns
#     → 下次跑 packaging/build.sh 时自动拷入 WirelessMic.app/Contents/Resources/
#
# 要求：macOS 自带的 sips 与 iconutil（命令行工具即可，不需要 Xcode.app）。
# 缺失处理：iconutil 或 sips 不存在、PNG 不存在时，本脚本明确提示并跳过，
#           以状态 0 退出，不中断后续打包（图标本来就是可选的）。
# 生成失败（尺寸转换或 icns 合成出错）时返回非 0 并打印原因。

set -euo pipefail

SCRIPT_DIR="${0:A:h}"            # 本脚本所在目录：packaging/
PNG_SRC="${SCRIPT_DIR}/AppIcon.png"
ICONSET_DIR="${SCRIPT_DIR}/AppIcon.iconset"
ICON_OUT="${SCRIPT_DIR}/AppIcon.icns"

# 跳过图标：打印原因，以状态 0 退出。
skip() {
  print "⏭️ 跳过图标：$1"
  print "   如需图标：把 1024x1024 的 PNG 放到 packaging/AppIcon.png，再跑 zsh packaging/icon.sh"
  exit 0
}

command -v iconutil >/dev/null 2>&1 || skip "没有找到 iconutil（本机只有命令行工具且未提供 iconutil）"
command -v sips >/dev/null 2>&1 || skip "没有找到 sips"
[[ -f "$PNG_SRC" ]] || skip "没有找到 ${PNG_SRC}"

# 尺寸检查：不是 1024x1024 时只警告，继续做（iconutil 接受缩放后的尺寸）。
width="$(sips -g pixelWidth "$PNG_SRC" | awk '/pixelWidth/{print $2}')"
height="$(sips -g pixelHeight "$PNG_SRC" | awk '/pixelHeight/{print $2}')"
if [[ "$width" != "1024" || "$height" != "1024" ]]; then
  print "⚠️ 警告：${PNG_SRC} 是 ${width}x${height}，不是 1024x1024，仍继续生成（建议换成 1024x1024 以获得最佳效果）"
fi

print "▶ 生成 iconset…"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR" || {
  print -u2 "❌ 无法创建 ${ICONSET_DIR}"
  exit 1
}

# 尺寸表：输出文件名:边长（iconutil 要求的 10 张固定尺寸）。
size_specs=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)
for spec in "${size_specs[@]}"; do
  name="${spec%%:*}"
  size="${spec##*:}"
  sips -z "$size" "$size" "$PNG_SRC" --out "${ICONSET_DIR}/${name}" >/dev/null || {
    print -u2 "❌ 图标生成失败：sips 无法生成 ${name}（${size}x${size}）"
    print -u2 "   建议：确认 ${PNG_SRC} 是有效的 PNG；换一张 1024x1024 的 PNG 再试"
    exit 1
  }
done

print "▶ 合成 icns…"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUT" || {
  print -u2 "❌ 图标生成失败：iconutil 合成 icns 失败"
  print -u2 "   建议：确认 iconset 里的 10 张 PNG 齐全且为 PNG 格式；删掉 ${ICONSET_DIR} 后重跑"
  exit 1
}
rm -rf "$ICONSET_DIR"

print "✅ 图标已生成：${ICON_OUT}"
print "   下次跑 zsh packaging/build.sh 时会自动拷入应用包的 Contents/Resources/"
