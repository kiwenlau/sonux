#!/bin/bash
# 全自动收尾：扫完全库 → 精炼 → 无损切除 → 自动验收 →（达标才）替换原件 → 重映射进度 → 同步模拟器与 iPhone。
#
#   ./tools/adcheck-autopilot.sh                 # 默认 6 并行
#   ./tools/adcheck-autopilot.sh --jobs 4        # 改并行度
#   ./tools/adcheck-autopilot.sh --no-device     # 不碰 iPhone（只处理本机与模拟器）
#
# 进度随时看：./tools/adcheck-status.sh
#
# 安全设计：
#   · 验收不达标（通过率 <99%，或有任何「清单与文件不一致 / 不是无损原声」）就停在替换之前，只留 TestBooks-clean/
#   · 替换前把原文件搬到 TestBooks-original/（不删除任何原始音频）
#   · 每一步都可重复执行：扫描跳过已转写的章，切除与验收按当前清单重算
set -uo pipefail
cd "$(dirname "$0")/.."
JOBS=6
NODEV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="${2:-6}"; shift 2 ;;
    --no-device) NODEV=1; shift ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done
LOG=.tmp-adcheck/autopilot.log
REPORT=.tmp-adcheck/autopilot-report.txt
BUNDLE=com.kiwenlau.sonux
mkdir -p .tmp-adcheck
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "===== 1/7 全库扫描（$JOBS 并行）"
for round in 1 2 3 4; do
  out=$(python3 tools/adcheck.py --all --jobs "$JOBS" >> tools/adcheck.jsonl 2>>"$LOG")
  say "  第 $round 轮：$(echo "$out" | grep -E '^共 ' | head -1)"
  echo "$out" | grep -q "本轮 0 章" && break
done

say "===== 2/7 跨章精炼"
python3 tools/adcheck-refine.py --jobs 5 2>>"$LOG" | tail -3 | tee -a "$LOG"

say "===== 3/7 无损切除到 TestBooks-clean/"
python3 tools/adcut-apply.py --apply 2>>"$LOG" | grep -E "^清单|已写入" | tee -a "$LOG"

say "===== 4/7 自动验收（每刀硬指标 + 内容证据 + 整章重转写抽查）"
python3 tools/adcheck-audit.py --jobs 5 --deep 30 2>>"$LOG" | grep -E "^验收|^切口|^整章|^证据" | tee -a "$LOG"

say "===== 5/7 验收闸门"
if python3 - <<'PY' 2>>"$LOG"
import csv, sys
rows = list(csv.DictReader(open("tools/adcheck-audit.csv")))
cuts = [r for r in rows if r["cut"] not in ("", "整章重转写")]
bad = [r for r in cuts if r["verdict"] != "通过"]
hard = [r for r in rows if "清单与文件不一致" in r["hard"] or "不是无损原声" in r["hard"]]
rate = 1 - len(bad) / max(len(cuts), 1)
print(f"  切口 {len(cuts)}，未通过 {len(bad)}，通过率 {rate:.2%}，硬性不合格 {len(hard)}")
for r in bad[:8]:
    print("   ⚠️", r["file"].split("/", 1)[1][:44], r["cut"], r["why"][:50])
sys.exit(0 if rate >= 0.99 and not hard else 1)
PY
then
  say "  ✅ 达标，继续替换原件"
else
  say "  ⛔ 未达标：不替换 TestBooks/ 原件。请查 tools/adcheck-audit.csv 后手动执行 adcut-apply.py --promote"
  exit 1
fi

say "===== 6/7 替换原件（原文件移到 TestBooks-original/）"
python3 tools/adcut-apply.py --promote 2>>"$LOG" | tail -2 | tee -a "$LOG"

say "===== 7/7 重映射收听进度并同步"
SIMDOC="$(xcrun simctl get_app_container booted "$BUNDLE" data 2>/dev/null)/Library/Application Support/progress.json"
if [ -f "$SIMDOC" ]; then
  python3 tools/adcheck-remap-progress.py "$SIMDOC" 2>>"$LOG" | tail -2 | tee -a "$LOG"
fi
xcrun simctl terminate booted "$BUNDLE" 2>/dev/null
./sync-to-sim.sh TestBooks/*/ 2>>"$LOG" | tail -2 | tee -a "$LOG"
xcrun simctl launch booted "$BUNDLE" >/dev/null 2>&1 && say "  模拟器里的 App 已重启"

DEV=""
if [ "$NODEV" = "1" ]; then
  say "  按你的要求跳过 iPhone 真机（不检测、不同步）。需要时手动执行：./sync-to-device.sh TestBooks/*/"
else
for i in $(seq 1 24); do
  DEV="$(xcrun devicectl list devices 2>/dev/null | grep physical | grep connected \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{10,}' | head -1)"
  [ -n "$DEV" ] && break
  [ $((i % 6)) -eq 1 ] && say "  iPhone 未连接，等待插入（第 $i 次检查）"
  sleep 300
done
if [ -n "$DEV" ]; then
  say "  检测到 iPhone $DEV，开始同步（约 7GB，需要一段时间）"
  ./sync-to-device.sh TestBooks/*/ 2>>"$LOG" | tail -3 | tee -a "$LOG"
  TMP="$(mktemp -d)"
  if xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
       --domain-identifier "$BUNDLE" \
       --source "Library/Application Support/progress.json" --destination "$TMP" >/dev/null 2>&1 \
     && [ -f "$TMP/progress.json" ]; then
    python3 tools/adcheck-remap-progress.py "$TMP/progress.json" 2>>"$LOG" | tail -1 | tee -a "$LOG"
    xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source "$TMP/progress.json" \
      --destination "Library/Application Support/progress.json" >/dev/null 2>&1 \
      && say "  iPhone 收听进度已换算到新时间轴"
  else
    say "  ️ 读不到 iPhone 上的 progress.json（真机沙盒限制），进度交由 App 自行钳位处理"
  fi
  rm -rf "$TMP"
else
  say "  ️ 等待 2 小时内没检测到已连接的 iPhone，未同步真机。插上后执行：./sync-to-device.sh TestBooks/*/"
fi
fi

say "===== 完成"
{
  echo "Sonux 广告切除 · 完成报告 $(date '+%F %H:%M')"
  echo "清单章节数: $(grep -c . tools/adcuts.jsonl)"
  echo "切除总量（全库统计）:"
  python3 tools/adcheck.py --report 2>/dev/null | sed -n '1,2p' | sed 's/^/  /'
  echo "验收: $(grep -E '^切口' "$LOG" | tail -1)"
  echo "原始文件备份: TestBooks-original/"
} | tee "$REPORT"
say "报告见 $REPORT"
