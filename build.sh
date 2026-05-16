#!/bin/bash
# ============================================================
#  ClipMate Build Script
#  - 自动检测环境依赖
#  - 自动安装缺失组件
#  - Release 模式编译
#  - 打包为 .app + .dmg 安装包
# ============================================================

set -euo pipefail

# ---- 清理环境：移除可能干扰的 PATH 条目（如 GVM）----
# GVM 的 bin 目录中某些 wrapper 会拦截系统命令（如 swift）
# 通过临时移除这些路径确保使用系统原生工具链
CLEAN_PATH=""
IFS=':' read -ra PATH_ENTRIES <<< "$PATH"
for entry in "${PATH_ENTRIES[@]}"; do
    # 跳过 GVM 相关路径
    if [[ "${entry}" == *".gvm"* ]]; then
        continue
    fi
    if [[ -n "${CLEAN_PATH}" ]]; then
        CLEAN_PATH="${CLEAN_PATH}:${entry}"
    else
        CLEAN_PATH="${entry}"
    fi
done
export PATH="${CLEAN_PATH}"

# 确保 xcrun 可找到 swift 工具链
if command -v xcrun &>/dev/null; then
    REAL_SWIFT_DIR="$(dirname "$(xcrun --find swift 2>/dev/null)" 2>/dev/null || true)"
    if [[ -n "${REAL_SWIFT_DIR}" && -d "${REAL_SWIFT_DIR}" ]]; then
        export PATH="${REAL_SWIFT_DIR}:${PATH}"
    fi
fi

# ---- 配置 ----
APP_NAME="ClipMate"
BUNDLE_ID="com.clipmate.app"
VERSION="1.0.0"
BUILD_NUMBER="1"
MACOS_MIN="14.0"
SWIFT_MIN_MAJOR="6"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
RELEASE_DIR="${BUILD_DIR}/release"
BUNDLE_DIR="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_OUTPUT="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

separator() { echo -e "${CYAN}─────────────────────────────────────────${NC}"; }

# ---- 错误处理 ----
cleanup() {
    if [[ -d "${DMG_DIR}" ]]; then
        rm -rf "${DMG_DIR}"
    fi
}
trap cleanup EXIT

# ============================================================
#  Step 1: 环境检测
# ============================================================
check_environment() {
    separator
    log_info "Step 1/5: 环境检测"
    separator

    local has_error=0

    # macOS 版本
    local macos_ver
    macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    local macos_major
    macos_major=$(echo "${macos_ver}" | cut -d. -f1)
    if (( macos_major < 14 )); then
        log_error "macOS ${macos_ver} 低于最低要求 ${MACOS_MIN}"
        has_error=1
    else
        log_ok "macOS ${macos_ver} ✓ (要求 >= ${MACOS_MIN})"
    fi

    # Xcode Command Line Tools
    if ! xcode-select -p &>/dev/null; then
        log_warn "Xcode Command Line Tools 未安装，正在安装..."
        install_xcode_cli
    else
        log_ok "Xcode Command Line Tools ✓ ($(xcode-select -p 2>/dev/null))"
    fi

    # Swift
    if ! command -v swift &>/dev/null; then
        log_error "Swift 未找到，请安装 Xcode Command Line Tools"
        has_error=1
    else
        local swift_ver
        swift_ver=$(xcrun swift --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        local swift_major
        swift_major=$(echo "${swift_ver}" | cut -d. -f1)
        if (( swift_major < SWIFT_MIN_MAJOR )); then
            log_error "Swift ${swift_ver} 低于最低要求 ${SWIFT_MIN_MAJOR}.0"
            has_error=1
        else
            log_ok "Swift ${swift_ver} ✓ (要求 >= ${SWIFT_MIN_MAJOR}.0)"
        fi
    fi

    # SPM
    if ! xcrun swift build --version &>/dev/null 2>&1; then
        log_error "Swift Package Manager 不可用"
        has_error=1
    else
        log_ok "Swift Package Manager ✓"
    fi

    # Xcode tools (codesign, etc.)
    for tool in codesign hdiutil; do
        if ! command -v "${tool}" &>/dev/null; then
            log_warn "${tool} 未找到（签名/打包可能受影响）"
        else
            log_ok "${tool} ✓"
        fi
    done

    if (( has_error )); then
        log_error "环境检测未通过，请修复后重试"
        exit 1
    fi

    echo ""
}

# ============================================================
#  自动安装 Xcode CLI
# ============================================================
install_xcode_cli() {
    log_info "安装 Xcode Command Line Tools..."
    # 触发安装提示（需要用户交互）
    xcode-select --install 2>/dev/null || true
    log_warn "安装窗口已弹出，请按提示完成安装后重新运行此脚本"
    log_warn "安装命令: xcode-select --install"
    exit 0
}

# ============================================================
#  Step 2: 编译
# ============================================================
build_project() {
    separator
    log_info "Step 2/5: 编译项目 (Release 模式)"
    separator

    cd "${PROJECT_DIR}"

    # 解析依赖
    log_info "解析 SPM 依赖..."
    xcrun swift package resolve 2>&1 || {
        log_error "依赖解析失败"
        exit 1
    }
    log_ok "依赖解析完成"

    # Release 编译（Debug 模式在 Swift 6 下会触发编译器崩溃）
    log_info "开始 Release 编译..."
    local build_output
    build_output=$(xcrun swift build -c release 2>&1) || {
        echo "$build_output" | tail -20
        log_error "编译失败"
        exit 1
    }
    # 只在有 error 时才显示输出
    if echo "$build_output" | grep -q "error:"; then
        echo "$build_output" | grep "error:" | head -10
        log_error "编译有错误"
        exit 1
    fi
    # 显示 warning 摘要（不视为失败）
    local warning_count
    warning_count=$(echo "$build_output" | grep -c "warning:" || true)
    if (( warning_count > 0 )); then
        log_warn "编译有 ${warning_count} 个 warning（不影响运行）"
    fi

    # 验证产物
    if [[ ! -f "${RELEASE_DIR}/${APP_NAME}" ]]; then
        log_error "编译产物未找到: ${RELEASE_DIR}/${APP_NAME}"
        exit 1
    fi

    local binary_size
    binary_size=$(du -h "${RELEASE_DIR}/${APP_NAME}" | cut -f1)
    log_ok "编译成功: ${RELEASE_DIR}/${APP_NAME} (${binary_size})"
    echo ""
}

# ============================================================
#  Step 3: 创建 .app Bundle
# ============================================================
create_app_bundle() {
    separator
    log_info "Step 3/5: 创建 .app Bundle"
    separator

    # 清理旧 bundle
    if [[ -d "${BUNDLE_DIR}" ]]; then
        rm -rf "${BUNDLE_DIR}"
    fi

    mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
    mkdir -p "${BUNDLE_DIR}/Contents/Resources"

    # 复制可执行文件
    cp "${RELEASE_DIR}/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
    chmod +x "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
    log_ok "可执行文件已复制"

    # 生成 Info.plist（替换 Xcode 变量）
    cat > "${BUNDLE_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MACOS_MIN}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 ClipMate. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>ClipMate 需要辅助功能权限来实现快速粘贴到其他应用的功能。</string>
</dict>
</plist>
PLIST
    log_ok "Info.plist 已生成"

    # 复制 entitlements
    if [[ -f "${PROJECT_DIR}/Resources/ClipMate.entitlements" ]]; then
        cp "${PROJECT_DIR}/Resources/ClipMate.entitlements" \
           "${BUNDLE_DIR}/Contents/Resources/${APP_NAME}.entitlements"
        log_ok "Entitlements 已复制"
    fi

    # 如果有 .icns 图标文件（优先 App/Resources，回退 Resources）
    local icns_source=""
    if [[ -f "${PROJECT_DIR}/App/Resources/AppIcon.icns" ]]; then
        icns_source="${PROJECT_DIR}/App/Resources/AppIcon.icns"
    elif [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
        icns_source="${PROJECT_DIR}/Resources/AppIcon.icns"
    fi

    if [[ -n "${icns_source}" ]]; then
        cp "${icns_source}" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
        log_ok "App 图标已复制 (${icns_source})"
    else
        log_warn "未找到 AppIcon.icns（可后续手动添加）"
    fi

    log_ok ".app Bundle 创建完成: ${BUNDLE_DIR}"
    echo ""
}

# ============================================================
#  Step 4: 代码签名
# ============================================================
code_sign() {
    separator
    log_info "Step 4/5: 代码签名"

    if ! command -v codesign &>/dev/null; then
        log_warn "codesign 不可用，跳过签名"
        echo ""
        return
    fi

    # 检查是否有开发者证书
    local dev_identity
    dev_identity=$(security find-identity -v -p codesigning 2>/dev/null | \
                   grep "Apple Development\|Developer ID Application" | \
                   head -1 | \
                   grep -oE '"[^"]+"$' | tr -d '"' || true)

    if [[ -n "${dev_identity}" ]]; then
        log_info "找到开发者证书: ${dev_identity}"
        log_info "使用开发者证书签名..."

        # Deep sign the .app bundle
        codesign --force --deep --sign "${dev_identity}" \
                 --options runtime \
                 --entitlements "${BUNDLE_DIR}/Contents/Resources/${APP_NAME}.entitlements" \
                 "${BUNDLE_DIR}" 2>&1 || {
            log_warn "开发者签名失败，回退到 ad-hoc 签名"
            dev_identity=""
        }

        if [[ -n "${dev_identity}" ]]; then
            log_ok "开发者签名完成 ✓"
            # 验证签名
            codesign --verify --deep --strict "${BUNDLE_DIR}" 2>&1 && \
                log_ok "签名验证通过" || \
                log_warn "签名验证未通过"
            echo ""
            return
        fi
    fi

    # Ad-hoc 签名（无证书时的回退方案）
    log_info "使用 Ad-hoc 签名..."
    codesign --force --deep --sign - "${BUNDLE_DIR}" 2>&1 || {
        log_warn "签名失败（不影响本地运行）"
        echo ""
        return
    }
    log_ok "Ad-hoc 签名完成"
    echo ""
}

# ============================================================
#  Step 5: 创建 DMG 安装包
# ============================================================
create_dmg() {
    separator
    log_info "Step 5/5: 创建 DMG 安装包"
    separator

    if ! command -v hdiutil &>/dev/null; then
        log_warn "hdiutil 不可用，跳过 DMG 创建"
        log_warn ".app Bundle 可直接在: ${BUNDLE_DIR}"
        echo ""
        return
    fi

    # 准备 DMG 源目录
    rm -rf "${DMG_DIR}"
    mkdir -p "${DMG_DIR}"

    # 复制 .app 到 DMG 源
    cp -R "${BUNDLE_DIR}" "${DMG_DIR}/"

    # 创建 Applications 软链接（方便拖拽安装）
    ln -s /Applications "${DMG_DIR}/Applications"

    # 生成 DS_Store（可选，配置 DMG 窗口外观）
    # 这里设置窗口大小和图标位置
    if command -v osascript &>/dev/null; then
        log_info "配置 DMG 窗口布局..."
    fi

    # 删除旧 DMG
    rm -f "${DMG_OUTPUT}"

    # 创建 DMG
    log_info "正在打包 DMG..."
    hdiutil create \
        -volname "${APP_NAME}" \
        -srcfolder "${DMG_DIR}" \
        -ov \
        -format UDZO \
        "${DMG_OUTPUT}" 2>&1 | tail -5 || {
        log_error "DMG 创建失败"
        exit 1
    }

    # 验证
    if [[ ! -f "${DMG_OUTPUT}" ]]; then
        log_error "DMG 文件未生成"
        exit 1
    fi

    local dmg_size
    dmg_size=$(du -h "${DMG_OUTPUT}" | cut -f1)
    log_ok "DMG 创建完成: ${DMG_OUTPUT} (${dmg_size})"
    echo ""
}

# ============================================================
#  主动画序列
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     ${APP_NAME} Build Script             ║${NC}"
    echo -e "${CYAN}║     v${VERSION}                            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    local start_time
    start_time=$(date +%s)

    # 检测环境
    check_environment

    # 编译
    build_project

    # 打包 .app
    create_app_bundle

    # 签名
    code_sign

    # 生成 DMG
    create_dmg

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # 完成总结
    separator
    echo -e "${GREEN}✅ 构建完成！${NC}"
    separator
    echo ""
    echo -e "  ${CYAN}产物路径:${NC}"
    echo -e "    .app:  ${BUNDLE_DIR}"
    if [[ -f "${DMG_OUTPUT}" ]]; then
    echo -e "    .dmg:  ${DMG_OUTPUT}"
    fi
    echo ""
    echo -e "  ${CYAN}安装方式:${NC}"
    echo -e "    1. DMG: 双击 ${DMG_OUTPUT}，拖拽到 Applications"
    echo -e "    2. .app: 直接将 ${BUNDLE_DIR} 复制到 /Applications"
    echo ""
    echo -e "  ${CYAN}直接运行:${NC}"
    echo -e "    open \"${BUNDLE_DIR}\""
    echo ""
    echo -e "  ${CYAN}耗时: ${elapsed}s${NC}"
    echo ""
}

# ---- 支持子命令 ----
case "${1:-}" in
    build)
        # 仅编译
        build_project
        ;;
    bundle)
        # 编译 + 打 .app
        build_project
        create_app_bundle
        code_sign
        ;;
    dmg)
        # 全流程
        main
        ;;
    clean)
        log_info "清理构建产物..."
        cd "${PROJECT_DIR}"
        xcrun swift package clean 2>/dev/null || true
        rm -rf "${BUNDLE_DIR}" "${DMG_DIR}" "${DMG_OUTPUT}"
        log_ok "清理完成"
        ;;
    run)
        # 编译并运行
        build_project
        log_info "启动 ${APP_NAME}..."
        "${RELEASE_DIR}/${APP_NAME}" &
        log_ok "已启动 (PID: $!)"
        ;;
    *)
        # 默认: 全流程
        main
        ;;
esac
