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
    *)
      if [ ! -e "$1" ]; then
        echo "⚠️  跳过（不存在）：$1"
      else
        ITEMS+=("$1")
      fi
      shift ;;
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

# ---------- 传输 ----------
# 注意：devicectl 的 --destination 是「目标路径」而不是「目标目录」：
#   - 单个文件 + --destination /Documents 会把 Documents 整个目录覆盖成该文件！
#   - 正确写法：目标写全路径；文件夹末尾加 / 表示复制进该目录。
# 因此这里逐条传输，每个条目都指定完整目标路径。
TOTAL=${#ITEMS[@]}
INDEX=0
IMPORTED=0
for item in "${ITEMS[@]}"; do
  INDEX=$((INDEX + 1))
  name="$(basename "$item")"
  if [ -d "$item" ]; then
    dest="/Documents/$name/"   # 末尾斜杠：把文件夹整个复制进 Documents
  else
    dest="/Documents/$name"    # 目标写全文件名：文件落在 Documents 内
  fi
  echo " [$INDEX/$TOTAL] $name"
  if xcrun devicectl device copy to \
      --device "$DEVICE" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source "$item" \
      --destination "$dest" >/dev/null 2>&1; then
    IMPORTED=$((IMPORTED + 1))
  else
    echo "   ⚠️  传输失败，已跳过：$item"
    echo "      常见原因：iPhone 锁定 / 未信任本机 / App 未安装（先在 Xcode 运行一次）"
  fi
done

if [ "$IMPORTED" -eq 0 ]; then
  echo "❌ 全部传输失败。"
  exit 1
fi

echo ""
echo "✅ 完成，成功传输 $IMPORTED/$TOTAL 个条目（devicectl 会跳过未修改的文件，重复执行=增量同步）。"
echo "   打开 iPhone 上的 Sonux，点「刷新/重新扫描」即可看到新书。"
echo "   目标位置：$BUNDLE_ID 沙盒 Documents"
