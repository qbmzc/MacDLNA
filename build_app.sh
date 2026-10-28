#!/bin/bash
set -e

# ==========================================================
# MacDLNA 自动化编译与 App 封装脚本 (无 Xcode.app 纯命令行)
# ==========================================================

echo "=================================================="
echo "🔨 开始编译 MacDLNA (Release 模式)..."
echo "=================================================="

# 1. 执行 Swift Package Manager 编译
swift build -c release

# 2. 获取输出二进制绝对路径
BIN_DIR=$(swift build -c release --show-bin-path)
BIN_PATH="$BIN_DIR/MacDLNA"

if [ ! -f "$BIN_PATH" ]; then
    echo "❌ 未找到编译生成的可执行文件: $BIN_PATH"
    exit 1
fi

echo "✅ 编译成功: $BIN_PATH"

# 3. 创建 macOS App Bundle 目录结构
APP_NAME="MacDLNA.app"
CONTENTS_DIR="$APP_NAME/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "📦 正在封装 $APP_NAME ..."
rm -rf "$APP_NAME"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 4. 拷贝二进制程序
cp "$BIN_PATH" "$MACOS_DIR/MacDLNA"
chmod +x "$MACOS_DIR/MacDLNA"

# 5. 生成 Info.plist
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacDLNA</string>
    <key>CFBundleIdentifier</key>
    <string>com.macdlna.receiver</string>
    <key>CFBundleName</key>
    <string>MacDLNA</string>
    <key>CFBundleDisplayName</key>
    <string>MacDLNA</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- LSUIElement=true 使应用纯作为状态栏组件运行，不占用 Dock 栏图标 -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 允许加载 HTTP 明文音频流 (局域网 DLNA 投送均为 HTTP) -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <!-- macOS 局域网权限描述 -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>MacDLNA 需要访问本地局域网以接收来自手机音乐 App 的 DLNA 投送。</string>
</dict>
</plist>
EOF

# 6. 进行 Ad-Hoc 代码签名
echo "🔐 正在进行本地代码签名 (Ad-Hoc)..."
codesign --force --deep --sign - "$APP_NAME"

echo "=================================================="
echo "🎉 封装完成: $PWD/$APP_NAME"
echo ""
echo "▶️ 启动方式:"
echo "   open $APP_NAME"
echo "   或直接在终端运行: ./$APP_NAME/Contents/MacOS/MacDLNA"
echo "=================================================="
