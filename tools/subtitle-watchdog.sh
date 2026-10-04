#!/bin/bash
# 字幕流水线的外层看门狗：崩了就续跑，正常跑完（退出码 0）就收工不再重启。
#
# 为什么要单独一个文件：早先用一行 nohup bash -c 'while :; do ...; done' 临时拉起，
# 那个循环不看退出码，全库跑完后又把它重启了一次（空转）。
#
# 用法：nohup ./tools/subtitle-watchdog.sh > .tmp-adcheck/subtitle-watchdog.log 2>&1 &
set -u
cd "$(dirname "$0")/.."
while true; do
  ./tools/subtitle-autopilot.sh >> .tmp-adcheck/subtitle-autopilot.log 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "[$(date '+%F %T')] 流水线正常跑完（退出码 0），看门狗收工"
    break
  fi
  echo "[$(date '+%F %T')] 流水线异常退出（码 $rc），60 秒后自动续跑"
  sleep 60
done
