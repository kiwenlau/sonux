#!/bin/bash
# 看广告切除流水线进度：./tools/adcheck-status.sh
#
# 输出：当前在第几步、扫描完成度与预计剩余时间、切除/验收/替换的状态、日志尾部。
# 幂等，随时可跑，不会影响正在执行的任务。
set -uo pipefail
cd "$(dirname "$0")/.."
LOG=.tmp-adcheck/autopilot.log
STAMP=.tmp-adcheck/.status-last

TOTAL=$(find TestBooks -name "*.mp3" | wc -l | tr -d ' ')
# 按「唯一章节」统计，不能直接数行数：并发写入会留下重复行与损坏行
DONE=$(python3 -c "
import json
s=set()
for l in open('tools/adcheck.jsonl'):
    try: r=json.loads(l)
    except Exception: continue
    if 'file' in r and not r.get('error'): s.add(r['file'])
print(len(s))" 2>/dev/null || echo 0)
RUN=$(pgrep -f "adcheck-autopilot.sh" >/dev/null && echo 1 || echo 0)
STEP=$(grep -oE "===== [0-9]/7 [^（]*" "$LOG" 2>/dev/null | tail -1)

# 用上次快照算实时速率与 ETA（第一次跑只给完成度）
ETA="—"
NOW=$(date +%s)
if [ -f "$STAMP" ]; then
  read -r PDONE PTIME < "$STAMP"
  DT=$((NOW - PTIME)); DN=$((DONE - PDONE))
  if [ "$DN" -gt 0 ] && [ "$DT" -gt 0 ]; then
    LEFT=$(( (TOTAL - DONE) * DT / DN ))
    ETA="约 $((LEFT / 60)) 分钟（实测 $((DN * 60 / DT)) 章/分钟）"
  elif [ "$RUN" = "0" ]; then
    ETA="已停"
  fi
fi
echo "$DONE $NOW" > "$STAMP"

echo "Sonux 广告切除 · $(date '+%H:%M:%S')"
echo "  进程      : $([ "$RUN" = "1" ] && echo "运行中（$(pgrep -f spawn_main | wc -l | tr -d ' ') 个转写 worker）" || echo "未运行")"
echo "  当前步骤  : ${STEP:-尚未开始}"
if [ "$DONE" -gt "$TOTAL" ]; then DONE=$TOTAL; fi
echo "  扫描进度  : $DONE / $TOTAL 章（$((DONE * 100 / TOTAL))%）"
echo "  扫描剩余  : $ETA"
echo "  切除清单  : $(grep -c . tools/adcuts.jsonl 2>/dev/null || echo 0) 章"
echo "  干净书库  : $(find TestBooks-clean -name "*.mp3" 2>/dev/null | wc -l | tr -d ' ') 章 / $(du -sh TestBooks-clean 2>/dev/null | cut -f1 || echo '未生成')"
echo "  原件备份  : $([ -d TestBooks-original ] && echo "已建立（TestBooks/ 已换成干净版）" || echo "尚未替换原件")"
echo "  验收明细  : $(wc -l < tools/adcheck-audit.csv 2>/dev/null | tr -d ' ' || echo 0) 行"
HB=$(python3 -c "import os, glob, time; fs = glob.glob('tools/adcheck-cache/*.json'); print(int(time.time() - max(map(os.path.getmtime, fs))) if fs else -1)" 2>/dev/null)
echo "  心跳      : $([ "${HB:--1}" -ge 0 ] && echo "最近一章转写完成于 ${HB}s 前" || echo "无转写缓存")"
grep -E "切口 [0-9]+ 个|✅|⛔|完成报告|切除总量" "$LOG" 2>/dev/null | tail -4 | sed 's/^/  /'
[ -f .tmp-adcheck/autopilot-report.txt ] && { echo "  ── 最终报告 ──"; sed 's/^/  /' .tmp-adcheck/autopilot-report.txt; }
echo "  ── 日志末 3 行 ──"; tail -20 "$LOG" 2>/dev/null | grep -vE "Warning|mel_spec|self\.|^$" | tail -3 | sed 's/^/  /' || true
exit 0
