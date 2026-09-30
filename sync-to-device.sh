#!/bin/bash
# 把电脑上的音频文件传到已连接的 iPhone 上的 Sonux 书库（真机版 sync-to-sim.sh）
# 原理：App 开启了 UIFileSharingEnabled，用 xcrun devicectl 直接写入其沙盒 Documents
# 用法：
#   ./sync-to-device.sh ~/Music/歌单文件夹            （整个文件夹 = 一本多章节书）
#   ./sync-to-device.sh ~/Downloads/a.m4a b.mp3       （单个/多个文件 = 各自一本书）
#   ./sync-to-device.sh /Users/kiwenlau/Desktop/静雅思听/静雅思听优秀作品/*/     （通配符）
# 可选：
#   --device <UDID|名称>   指定设备（默认自动取第一台已连接的物理设备）
set -euo pipefail

BUNDLE_ID="com.kiwenlau.sonux"

# ---------- 解析参数 ----------
DEVICE=""
ITEMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --device=*) DEVICE="${1#--device=}"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) ITEMS+=("$1"); shift ;;
  esac
done

if [ "${#ITEMS[@]}" -eq 0 ]; then
  echo "用法：$0 <音频文件或文件夹> [更多...]"
  echo "      --device <UDID|名称>  指定设备（可选）"
  exit 1
fi

# ---------- 找设备 ----------
if [ -z "$DEVICE" ]; then
  # 在包含 physical 且 connected 的行里提取 UDID（形如 00008140-0010...）
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | grep physical | grep connected \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{10,}' | head -1)"
  # 退化为按名称匹配第一台已连接物理设备
  if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null \
      | grep physical | grep connected | head -1 | awk '{print $1}')"
  fi
fi

if [ -z "$DEVICE" ]; then
  echo "❌ 没找到已连接的 iPhone。请用数据线连接并解锁手机后重试。"
  echo "   当前设备列表："
  xcrun devicectl list devices
  exit 1
fi
echo "📱 目标设备：$DEVICE"

# ---------- 校验本地文件 ----------
SRC_ARGS=()
for item in "${ITEMS[@]}"; do
  if [ ! -e "$item" ]; then
    echo "⚠️  跳过（不存在）：$item"
    continue
  fi
  SRC_ARGS+=(--source "$item")
done
if [ "${#SRC_ARGS[@]}" -eq 0 ]; then
  echo "❌ 没有可传输的有效路径。"
  exit 1
fi

# ---------- 传输 ----------
echo "🚀 开始传输（devicectl 会跳过未修改的文件，重复执行=增量同步）..."
if ! xcrun devicectl device copy to \
    --device "$DEVICE" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    "${SRC_ARGS[@]}" \
    --destination /Documents; then
  echo ""
  echo "❌ 传输失败。常见原因："
  echo "   1. iPhone 处于锁定状态 —— 解锁手机后重试"
  echo "   2. 未信任本机 —— 手机上弹窗点「信任」"
  echo "   3. App 未安装 —— 先在 Xcode 里运行一次 Sonux"
  exit 1
fi

echo ""
echo "✅ 完成，共传输 ${#ITEMS[@]} 个条目。"
echo "   打开 iPhone 上的 Sonux，点「刷新/重新扫描」即可看到新书。"
echo "   目标位置：$BUNDLE_ID 沙盒 Documents"
