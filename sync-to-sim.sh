#!/bin/bash
# 把电脑上的音频文件传到当前已启动的 iOS 模拟器的 Sonux 书库
# 用法：
#   ./sync-to-sim.sh ~/Music/歌单文件夹            （整个文件夹 = 一本多章节书）
#   ./sync-to-sim.sh ~/Downloads/a.m4a b.mp3       （单个/多个文件 = 各自一本书）
#   ./sync-to-sim.sh ~/Music/**/*.{m4a,mp3,m4b}    （通配符）
set -euo pipefail

BUNDLE_ID="com.kiwenlau.sonux"

# 确认有模拟器处于启动状态
if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
  echo "❌ 没有正在运行的模拟器，请先在 Xcode 里启动一个 iPhone 模拟器。"
  exit 1
fi

# 取 Sonux 沙盒的 Documents 路径
DOC="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)/Documents" || {
  echo "❌ 模拟器上找不到 $BUNDLE_ID，请先在 Xcode 里运行一次 Sonux 安装它。"
  exit 1
}
mkdir -p "$DOC"

if [ "$#" -eq 0 ]; then
  echo "用法：$0 <音频文件或文件夹> [更多...]"
  echo "目标目录：$DOC"
  exit 1
fi

count=0
for item in "$@"; do
  if [ ! -e "$item" ]; then
    echo "⚠️  跳过（不存在）：$item"
    continue
  fi
  if [ -d "$item" ]; then
    cp -R "$item" "$DOC/"
    echo "📁 已复制文件夹：$item"
  else
    cp "$item" "$DOC/"
    echo "🎵 已复制文件：$item"
  fi
  count=$((count + 1))
done

echo ""
echo "✅ 完成，共处理 $count 项。"
echo "   回到模拟器里的 Sonux，点「刷新」或「重新扫描」即可看到。"
echo "   目标目录：$DOC"
