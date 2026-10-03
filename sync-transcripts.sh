#!/bin/bash
# 把仓库里的字幕包 transcripts/（tools/transcribe.py 生成）同步到模拟器与 iPhone 的 Sonux 沙盒
# 与 sync-library.sh 的区别：只增量补字幕，不动音频书库，也不删沙盒里多出来的东西。
#
# 用法：
#   ./sync-transcripts.sh              # 模拟器 + 已连接的 iPhone（没连就跳过真机）
#   ./sync-transcripts.sh --sim-only   # 只同步模拟器
#   ./sync-transcripts.sh --device-only
set -euo pipefail

BUNDLE_ID="com.kiwenlau.sonux"
SRC="$(cd "$(dirname "$0")" && pwd)/transcripts"
TO_SIM=1
TO_DEVICE=1

for arg in "$@"; do
  case "$arg" in
    --sim-only) TO_DEVICE=0 ;;
    --device-only) TO_SIM=0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

if [ ! -d "$SRC" ]; then
  echo "❌ 找不到字幕目录：$SRC（先跑 python3 tools/transcribe.py --all --pack）"
  exit 1
fi
COUNT=$(ls -1 "$SRC"/*.json 2>/dev/null | wc -l | tr -d ' ')
SIZE=$(du -sh "$SRC" | awk '{print $1}')
echo "📄 字幕包 $COUNT 本 / $SIZE"

# ---------- 模拟器 ----------
if [ "$TO_SIM" -eq 1 ]; then
  if xcrun simctl list devices booted | grep -q "(Booted)"; then
    DOC="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)/Documents"
    if [ -n "$DOC" ] && [ -d "$DOC" ]; then
      mkdir -p "$DOC/transcripts"
      # -a 保留时间戳只传改过的书；--delete 让沙盒与仓库一致：
      # 打包只收当前模型的章，换模型后旧模型那几本会被从仓库包里剔除，
      # 不删就会在设备上继续显示被淘汰的旧字幕
      rsync -a --delete --exclude '.DS_Store' --exclude '*.tmp' --exclude '*.part' "$SRC/" "$DOC/transcripts/"
      echo "📱 模拟器字幕已同步：$DOC/transcripts"
    else
      echo "⚠️  模拟器里没装 $BUNDLE_ID，跳过模拟器"
    fi
  else
    echo "⚠️  没有正在运行的模拟器，跳过模拟器"
  fi
fi

# ---------- iPhone 真机 ----------
if [ "$TO_DEVICE" -eq 1 ]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | grep physical | grep connected \
    | grep -oE '[0-9A-Fa-f]{8}-0010[0-9A-Fa-f]{7,}' | head -1)"
  if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null \
      | grep physical | grep connected | head -1 | awk '{print $1}')"
  fi
  if [ -z "$DEVICE" ]; then
    echo "⚠️  iPhone 未连接，跳过真机（插上后重跑本脚本）"
  else
    echo "📱 目标设备：$DEVICE"
    ok=0
    # 逐本传：devicectl 的 --destination 是完整目标路径，会跳过内容未变的文件
    for f in "$SRC"/*.json; do
      name="$(basename "$f")"
      if xcrun devicectl device copy to \
          --device "$DEVICE" \
          --domain-type appDataContainer \
          --domain-identifier "$BUNDLE_ID" \
          --source "$f" \
          --destination "/Documents/transcripts/$name" >/dev/null 2>&1; then
        ok=$((ok + 1))
      else
        echo "   ⚠️  传输失败：$name（常见原因：iPhone 锁定 / 未信任本机）"
      fi
    done
    echo "✅ 真机字幕已同步 $ok/$COUNT 本"
    echo "   在 iPhone 的 Sonux 里点「刷新」或重进播放页即可看到字幕"
  fi
fi
