#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "WaterPad 工程生成"
echo "要求：macOS、Xcode 15 或更新版本、XcodeGen、Apple Developer 账号"
echo ""

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未找到 XcodeGen。"
  if command -v brew >/dev/null 2>&1; then
    read -r -p "现在用 Homebrew 安装 XcodeGen 吗？[y/N] " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
      brew install xcodegen
    else
      echo "请先执行 brew install xcodegen，然后重新运行本脚本。"
      exit 1
    fi
  else
    echo "请先安装 Homebrew，再执行 brew install xcodegen。"
    exit 1
  fi
fi

echo "正在生成 Xcode 工程..."
xcodegen generate

echo ""
echo "已生成 WaterPad.xcodeproj"
echo "后续步骤："
echo "  1. 用 Xcode 打开工程，在 Signing & Capabilities 里选择你的 Team"
echo "  2. 连接 iPhone 真机，选择该设备后运行"
echo "  3. 打开应用后点顶部「开始广播」"
echo "  4. 在主机（Windows / 安卓 / iPad）的系统蓝牙设置里搜索并配对"
echo ""
echo "提醒：模拟器没有 Core Haptics，也不能广播蓝牙外设，必须用真机测试。"
echo "提醒：广播用 16 位服务编号、GATT 注册用 128 位，两者不可混用。"
echo "提醒：主机显示的名称可能是 iPhone 整机名称，不是广播名 WaterPad。"
echo "提醒：iPad 对手柄类别的接管情况尚未验证，以真机结果为准。"

if command -v open >/dev/null 2>&1; then
  open WaterPad.xcodeproj
fi
