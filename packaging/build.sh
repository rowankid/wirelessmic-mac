#!/bin/zsh
# 无线麦 Mac 版打包脚本
#
# 用法（在工程根目录 wirelessmic-mac 下）：
#   zsh packaging/build.sh
#
# 产物（全部在 dist/）：
#   dist/WirelessMic.app   可直接运行的应用包
#   dist/WirelessMic.dmg   安装镜像（卷名“无线麦”，含 Applications 替身）
#   dist/WirelessMic.zip   备选压缩包
#
# 环境要求：只需要 macOS 命令行工具（/usr/bin/swift），不需要 Xcode.app。
# 签名方式：优先用钥匙串里的 “WirelessMic Local” 固定证书签名（授权跨构建保留），
# 没有该证书时回落到 ad-hoc（每次构建签名都会变，系统会重新要授权）。
# 沙盒：本应用需要 IOKit（读取 HID 按键）与 CGEvent（模拟按键），
#       因此必须是非沙盒应用，本脚本不加任何 entitlements。

set -euo pipefail

# ---------- 配置：全部变量集中定义 ----------
APP_NAME="WirelessMic"
VOL_NAME="无线麦"

SCRIPT_DIR="${0:A:h}"            # 本脚本所在目录：packaging/
ROOT_DIR="${SCRIPT_DIR:h}"       # 工程根目录：wirelessmic-mac/
PLIST_SRC="${SCRIPT_DIR}/Info.plist"
ICON_SRC="${SCRIPT_DIR}/AppIcon.icns"

DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
BIN_SRC="${ROOT_DIR}/.build/release/${APP_NAME}"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"
STAGING_DIR="${DIST_DIR}/.dmg-staging"

# ---------- 通用失败输出 ----------
# 用法：fail "步骤名" "原因" "下一步建议"
fail() {
  print -u2 ""
  print -u2 "❌ 构建失败：$1"
  print -u2 "   原因：$2"
  print -u2 "   建议：$3"
  exit 1
}

step() {
  print ""
  print "▶ $1"
}

# ---------- 0. 版本戳（防止用旧源码构建：每次发版改 VERSION，构建先打印它） ----------
if [[ -f "${ROOT_DIR}/VERSION" ]]; then
  print "工程版本：$(cat "${ROOT_DIR}/VERSION")"
else
  print "工程版本：未知（没有 VERSION 文件，可能是旧版工程）"
fi

# ---------- 1. 检查 Swift 工具链 ----------
step "1/10 检查 Swift 工具链"
command -v swift >/dev/null 2>&1 || fail "检查 Swift 工具链" \
  "没有找到 swift 命令" \
  "先安装命令行工具：xcode-select --install，装完重新打开终端再跑本脚本"

# ---------- 2. 检查工程文件 ----------
step "2/10 检查工程文件"
[[ -f "${ROOT_DIR}/Package.swift" ]] || fail "检查工程文件" \
  "在 ${ROOT_DIR} 下没有找到 Package.swift" \
  "请确认你是在 wirelessmic-mac 工程根目录运行本脚本（zsh packaging/build.sh）"
[[ -d "${ROOT_DIR}/Sources/${APP_NAME}" ]] || fail "检查工程文件" \
  "在 ${ROOT_DIR}/Sources 下没有找到 ${APP_NAME} 源码目录" \
  "请确认 Sources 已完整检出；如果刚克隆工程，先确认源码分支无误"
[[ -f "$PLIST_SRC" ]] || fail "检查工程文件" \
  "没有找到 ${PLIST_SRC}" \
  "请确认 packaging/Info.plist 存在（与 build.sh 同目录）"

# ---------- 3. 编译 ----------
step "3/10 编译（swift build -c release，可能需要几分钟）"
cd "$ROOT_DIR" || fail "进入工程目录" \
  "无法进入 ${ROOT_DIR}" \
  "检查目录权限"
# 把 VERSION 写进源码（日志启动时打印，方便远程排障确认构建版本）。
if [[ -f "${ROOT_DIR}/VERSION" ]]; then
  BUILD_VERSION="$(cat "${ROOT_DIR}/VERSION")"
else
  BUILD_VERSION="未知"
fi
printf '// 自动生成（packaging/build.sh 在编译前写入），不要手动改。\n// 供日志打印当前构建版本。\nenum BuildVersion {\n    static let string = "%s"\n}\n' "$BUILD_VERSION" > "${ROOT_DIR}/Sources/${APP_NAME}/GeneratedVersion.swift"
swift build -c release || fail "编译" \
  "swift build -c release 失败，上方有 Swift 编译错误" \
  "先修好 Sources 里的编译错误，再重新跑本脚本"
[[ -x "$BIN_SRC" ]] || fail "确认编译产物" \
  "编译完成但没有找到可执行文件 ${BIN_SRC}" \
  "删除 .build 后重试：rm -rf .build，再跑本脚本"

# ---------- 4. 组装 .app ----------
step "4/10 组装 ${APP_NAME}.app"
case "$APP_DIR" in
  "${ROOT_DIR}/dist/"*) ;;
  *) fail "清理旧产物" \
    "应用包路径异常：${APP_DIR}" \
    "不要手动改脚本里的 DIST_DIR，重新检出脚本再跑" ;;
esac
rm -rf "$APP_DIR" "$DMG_PATH" "$ZIP_PATH" "$STAGING_DIR" || fail "清理旧产物" \
  "无法删除 dist/ 下的旧产物" \
  "检查 dist/ 目录权限，或手动删除 dist/ 后重跑"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" || fail "创建 .app 目录" \
  "无法创建 ${APP_DIR} 的子目录" \
  "检查 dist/ 目录权限"
cp "$BIN_SRC" "$APP_DIR/Contents/MacOS/$APP_NAME" || fail "拷入可执行文件" \
  "无法把 ${BIN_SRC} 拷入应用包" \
  "检查磁盘空间与 dist/ 目录权限"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME" || fail "设置可执行权限" \
  "无法给应用包内的二进制加可执行权限" \
  "检查 dist/ 目录权限"
cp "$PLIST_SRC" "$APP_DIR/Contents/Info.plist" || fail "拷入 Info.plist" \
  "无法把 ${PLIST_SRC} 拷入应用包" \
  "确认 packaging/Info.plist 可读"
# SwiftPM 资源包（如果有）：目标声明了 Resources 处理时会出现，
# 没有也不报错——当前工程不一定有资源文件。
for bundle in "${ROOT_DIR}/.build/release/"*.bundle(N); do
  if [[ -d "$bundle" ]]; then
    cp -R "$bundle" "$APP_DIR/Contents/Resources/" && \
      print "   已拷入 SwiftPM 资源包：${bundle:t}"
  fi
done

# ---------- 5. 图标（可选） ----------
step "5/10 处理图标（可选）"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns" || fail "拷入图标" \
    "无法把 ${ICON_SRC} 拷入应用包" \
    "检查磁盘空间与 dist/ 目录权限"
  print "   已拷入图标：AppIcon.icns"
else
  print "   提示：没有找到 packaging/AppIcon.icns，跳过图标（不影响构建与运行）。"
  print "   如需图标：把 1024x1024 PNG 放到 packaging/AppIcon.png，跑 zsh packaging/icon.sh，再跑本脚本。"
fi

# ---------- 6. 签名（不加沙盒 entitlements，保留 IOKit 与 CGEvent 能力） ----------
# 签名身份决定了系统授权能不能跨版本保留，原理见 README-build.md“授权只需一次”：
#   ad-hoc（codesign --sign -）没有固定身份，每次构建签名都会变，
#   系统会把每个新构建当成一个新应用，蓝牙 / 输入监控 / 辅助功能全部重新弹窗。
#   用固定证书签名后，签名身份不变，授权只需给一次，之后构建都不用再授权。
# 身份选择顺序：环境变量 WIRELESSMIC_SIGN_IDENTITY > 钥匙串里的
# “WirelessMic Local”证书 > ad-hoc（并明确提示这是临时方案）。
step "6/10 签名（不加沙盒 entitlements，保留 IOKit 与 CGEvent 能力）"
SIGN_IDENTITY="${WIRELESSMIC_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q 'WirelessMic Local'; then
  SIGN_IDENTITY="WirelessMic Local"
fi
# 自签名证书在钥匙串里常显示为“未受信任”（CSSMERR_TP_NOT_TRUSTED），find-identity -v 看不到，
# 但 codesign 照样能用它签名，而且签名身份固定、系统授权可以跨构建保留。
# 钥匙串里若有多个同名证书，按 SHA-1 指纹固定使用下面这一个（本机命令行生成的那份）。
PINNED_SIGN_HASH="AFE92778648859FD3302F41A87322BAFDDEE8CFE"
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "$PINNED_SIGN_HASH"; then
  SIGN_IDENTITY="$PINNED_SIGN_HASH"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_MODE="证书（${SIGN_IDENTITY}）"
  print "   签名身份：${SIGN_IDENTITY}（固定身份，系统授权跨构建保留）"
else
  SIGN_IDENTITY="-"
  SIGN_MODE="ad-hoc（临时）"
  print "   签名身份：ad-hoc（没有固定身份，每次构建签名都会变）"
  print "   影响：每次构建后启动，系统都会重新弹窗要蓝牙 / 输入监控 / 辅助功能授权。"
  print "   一劳永逸：按 README-build.md“授权只需一次”创建一次 WirelessMic Local 证书，"
  print "   再跑本脚本就会自动用它签名，授权只需给一次。"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" || fail "签名" \
  "codesign 签名失败" \
  "证书签名失败时，先确认钥匙串里有该证书且 codesign 被允许访问（钥匙串弹窗点“始终允许”）；ad-hoc 签名不需要证书，如仍失败，删除 dist/ 后重跑"
print "   签名方式：${SIGN_MODE}"

# ---------- 7. 校验 ----------
step "7/10 校验签名与 Info.plist"
codesign -v "$APP_DIR" || fail "校验签名" \
  "codesign -v 校验未通过" \
  "删除 dist/ 后重新跑本脚本；如反复失败，检查是否有其他程序在占用应用包"
plutil -lint "$APP_DIR/Contents/Info.plist" || fail "校验 Info.plist" \
  "Info.plist 格式校验未通过" \
  "确认 packaging/Info.plist 是合法 XML（可用 plutil -lint packaging/Info.plist 单独检查）"

# ---------- 8. 制作 DMG ----------
step "8/10 制作 DMG（卷名：${VOL_NAME}）"
mkdir -p "$STAGING_DIR" || fail "准备 DMG 暂存目录" \
  "无法创建 ${STAGING_DIR}" \
  "检查 dist/ 目录权限"
cp -R "$APP_DIR" "$STAGING_DIR/" || fail "准备 DMG 内容" \
  "无法把应用包拷入 DMG 暂存目录" \
  "检查磁盘空间"
ln -s /Applications "$STAGING_DIR/Applications" || fail "准备 DMG 内容" \
  "无法在 DMG 暂存目录里创建 Applications 替身" \
  "检查 dist/ 目录权限"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" || fail "制作 DMG" \
  "hdiutil 创建 DMG 失败" \
  "检查磁盘空间（至少预留应用包两倍大小）；删除 dist/ 后重跑；如仍失败，可改用下面的 zip 备选"
rm -rf "$STAGING_DIR"

# ---------- 9. 制作 zip 备选（失败只警告，不中断——DMG 已可用） ----------
step "9/10 制作 zip 备选"
if ! (cd "$DIST_DIR" && ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip"); then
  print -u2 "⚠️ 警告：zip 备选制作失败（不影响 DMG 使用）"
  print -u2 "   建议：如需 zip，可手动执行：cd dist && ditto -c -k --keepParent ${APP_NAME}.app ${APP_NAME}.zip"
  ZIP_PATH=""
fi

# ---------- 10. 安装到固定路径（避免每次换位置、换签名重新授权） ----------
# 固定路径 + 固定签名，两个条件齐了，系统授权才能跨构建保留。
# 本步只警告不中断：安装失败时 DMG 仍可用，手动拖到 Applications 即可。
step "10/10 安装到 /Applications（固定路径，避免每次换位置重新授权）"
INSTALLED=0
if [[ -n "${WIRELESSMIC_NO_INSTALL:-}" ]]; then
  print "   已跳过（设置了 WIRELESSMIC_NO_INSTALL），请手动把 DMG 里的应用拖到 Applications"
elif pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  print "   检测到无线麦正在运行，已跳过自动安装（避免覆盖运行中的程序）。"
  print "   请退出无线麦后重跑一次本脚本，或手动把 dist/WirelessMic.app 拖到 Applications 替换。"
elif rm -rf "/Applications/${APP_NAME}.app" 2>/dev/null && ditto "$APP_DIR" "/Applications/${APP_NAME}.app" 2>/dev/null; then
  INSTALLED=1
  print "   已安装到 /Applications/${APP_NAME}.app，以后都从这里启动（不要再从 Downloads 的解压文件夹启动旧包）。"
else
  print -u2 "   ⚠️ 自动安装失败（可能是 /Applications 写权限），请手动把 DMG 里的应用拖到 Applications 替换。"
fi

# ---------- 完成 ----------
print ""
print "✅ 打包完成！"
print "   应用包：${APP_DIR}"
print "   DMG：${DMG_PATH}"
if [[ -n "$ZIP_PATH" && -f "$ZIP_PATH" ]]; then
  print "   zip：${ZIP_PATH}"
fi
print "   签名方式：${SIGN_MODE}"
print ""
print "下一步："
if [[ "$INSTALLED" == "1" ]]; then
  print "  已装到 /Applications/WirelessMic.app，直接从启动台或 /Applications 启动它。"
  if [[ "$SIGN_MODE" == "ad-hoc"* ]]; then
    print "  注意：这次仍是 ad-hoc 签名，启动后系统会再要一次授权；想以后都不用重复授权，"
    print "  按 README-build.md“授权只需一次”创建证书后重跑一次本脚本即可。"
  else
    print "  如果这是第一次用证书签名，启动后系统还会再要一次蓝牙 / 辅助功能授权（最后一次），"
    print "  允许后，之后每次构建都不用再授权了。"
  fi
else
  print "  1. 打开 ${DMG_PATH}，把 无线麦.app 拖到 Applications（固定路径，不要留在 Downloads 里启动）"
  print "  2. 首次启动请右键 → 打开（自签名证书和 ad-hoc 签名都会触发一次 Gatekeeper 提示，右键打开可放行，之后不用）"
  print "  3. 系统设置 → 隐私与安全性 → 蓝牙、辅助功能，允许 无线麦"
fi
print "  另行安装 BlackHole 虚拟麦克风（见 packaging/README-build.md）"
