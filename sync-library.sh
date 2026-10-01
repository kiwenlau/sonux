#!/bin/bash
# 把仓库里的 TestBooks/（测试书库，已整理过名称/作者/封面）镜像到已启动的 iOS 模拟器
# 与 sync-to-sim.sh 的区别：这个脚本做「镜像」，书库里多出来的旧书会被清掉，
# 并顺带清掉封面缓存（封面按书 id 缓存，改名后 id 变了）。
#
# 用法：
#   ./sync-library.sh              # 镜像同步（会先列出将被删除的条目）
#   ./sync-library.sh --no-delete  # 只新增/覆盖，不删模拟器上多出来的书
#   ./sync-library.sh --yes        # 不询问，直接删
set -euo pipefail

BUNDLE_ID="com.kiwenlau.sonux"
SRC="$(cd "$(dirname "$0")" && pwd)/TestBooks"
DO_DELETE=1
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --no-delete) DO_DELETE=0 ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
  echo "❌ 没有正在运行的模拟器，请先启动一个 iPhone 模拟器。"
  exit 1
fi

DOC="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)/Documents" || {
  echo "❌ 模拟器上找不到 $BUNDLE_ID，请先安装一次 Sonux。"
  exit 1
}
DATA="$(dirname "$DOC")"
mkdir -p "$DOC"

if [ ! -d "$SRC" ]; then
  echo "❌ 找不到源目录：$SRC"
  exit 1
fi

# 先停 App，避免扫描到一半
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true

if [ "$DO_DELETE" -eq 1 ]; then
  # 列出模拟器里有、仓库里没有的条目（这些会被删）
  EXTRA=()
  while IFS= read -r name; do
    [ -n "$name" ] && EXTRA+=("$name")
  done < <(comm -13 <(ls -1 "$SRC" | sort) <(ls -1 "$DOC" | sort))
  if [ "${#EXTRA[@]}" -gt 0 ]; then
    echo "⚠️  以下 ${#EXTRA[@]} 个条目只存在于模拟器，将被删除："
    printf '   - %s\n' "${EXTRA[@]}"
    if [ "$ASSUME_YES" -ne 1 ]; then
      read -r -p "   确认删除？[y/N] " reply
      if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
        echo "   已改为不删除。"
        DO_DELETE=0
      fi
    fi
  fi
fi

RSYNC_ARGS=(-a --exclude '.DS_Store')
# --delete-excluded：被排除的 .DS_Store 也要能删，否则旧书目录会因为只剩它而删不掉
[ "$DO_DELETE" -eq 1 ] && RSYNC_ARGS+=(--delete --delete-excluded)

echo "📚 镜像 $SRC → $DOC"
rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DOC/"

# 封面缓存按书 id 哈希，改名后全是无效条目，直接清空让 App 重新提取
if [ -d "$DATA/Library/Caches/Covers" ]; then
  rm -f "$DATA/Library/Caches/Covers"/*.jpg 2>/dev/null || true
  echo "🧹 已清封面缓存"
fi

echo "🚀 启动 Sonux…"
xcrun simctl launch booted "$BUNDLE_ID" >/dev/null

echo "✅ 完成：书库 $(ls -1 "$DOC" | wc -l | tr -d ' ') 本（源目录 $(ls -1 "$SRC" | wc -l | tr -d ' ') 本）"
