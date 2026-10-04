#!/bin/bash
# 字幕流水线看门狗：转写 → 打包同步 → 大模型纠错 → 打包同步，一轮一轮交替跑。
#
# 为什么交替跑：转写全库要十几小时，纠错又要十几小时；分批交替能让字幕一本一本
# 地出现，也保证两个吃内存的重活不会同时跑（上次 OOM 就是 5 个 whisper worker 叠
# 上别的模型进程）。并行数由脚本按当时可用内存现算，崩了自动重启续跑。
# 全程幂等：逐章结果都带 sig（音频字节数）与模型标记，重跑自动跳过已完成的章。
#
# 用法：
#   caffeinate -is ./tools/subtitle-autopilot.sh > .tmp-adcheck/subtitle-autopilot.log 2>&1 &
# 可调环境变量：
#   ASR_BATCH=120   每轮转写多少章    FIX_BATCH=60   每轮校对多少章
#   SKIP_FIX=1      只转写不校对
#   DASHSCOPE_API_KEY 或 ~/.config/sonux/llm-key   有密钥就用云端模型校对，没有用本地 14B
#   SONUX_LLM_MODEL / SONUX_LLM_BASE_URL   云端校对模型与入口（默认 qwen3.8-max + Token Plan）
#   FIX_WORKERS=8   云端校对并发（套餐有动态并发上限，触发 429 就调小）
# 进度随时可看：cat .tmp-adcheck/subtitle-status
set -uo pipefail
cd "$(dirname "$0")/.."
# 非 UTF-8 locale 下 bash 会把紧跟变量的全角标点当成变量名的一部分（set -u 直接炸），
# 这里显式要一个 UTF-8 locale。必须分两行写：export 的所有参数会先展开再赋值，
# 写成 `export LC_ALL=... LANG="$LC_ALL"` 会在赋值前读到未定义的 $LC_ALL
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG="$LC_ALL"

ASR_BATCH=${ASR_BATCH:-120}
FIX_BATCH=${FIX_BATCH:-200}   # 云端校对每轮跑够多章，才追得上转写的速度
# MLX 每个 worker 的 GPU 常驻区上限：whisper 模型才 1.6GB，给 2GB 足够。
# 不封这个的话 RSS 看着只占 2GB，实际 GPU 常驻区能把 48GB 机器顶到 OOM
export SONUX_MLX_WIRED_GB=${SONUX_MLX_WIRED_GB:-2}
QWEN=tools/models/Qwen2.5-14B-Instruct-4bit
FIX_PY=tools/.venv-mlx/bin/python3      # mlx-lm 只装在这个 venv 里
STATUS=.tmp-adcheck/subtitle-status

say() { echo "[$(date '+%F %T')] $*"; }
have_key() {
  [ -n "${DASHSCOPE_API_KEY:-}" ] || [ -n "${SONUX_LLM_API_KEY:-}" ] \
    || [ -f "${HOME}/.config/sonux/llm-key" ]
}
free_gb() { python3 -c 'import sys; sys.path.insert(0,"tools"); import transcribe as T; print(round(T.free_memory_gb()))' 2>/dev/null || echo "?"; }
count() {   # count <已做> <总数>：从 --status 里抓「已转写 N/M」
  python3 tools/transcribe.py --status 2>/dev/null | grep -oE "[0-9]+/[0-9]+ 章" | head -1; }

round=0
while true; do
  round=$((round+1))
  # 每轮重新判断后端：中途把密钥文件放进来，下一轮就自动切云端，不必重启流水线
  # 云端校对走百炼 Token Plan 套餐（Base URL 与模型名用 subtitle-fix.py 的默认值）。
  # 套餐里没包文件转写 ASR（实测 fun-asr / paraformer / *-filetrans 全部 Model not exist），
  # 所以转写仍由本地 whisper 出时间轴，文字交给云端改
  if have_key; then
    FIX_MODE=api
    # 不带引号是有意的：靠空白分词把参数传下去，这些参数里没有空格
    FIXARGS="--api --workers ${FIX_WORKERS:-8}"
  else
    FIX_MODE=local
    FIXARGS=""
  fi
  say "===== 第 ${round} 轮 · 可用内存 $(free_gb)GB · 校对后端 $FIX_MODE · 转写进度 $(count)"

  # 上一轮被强杀时可能留下孤儿 worker（SIGKILL 连 atexit 都跑不到）：一个本地校对
  # worker 吃 7.8GB，两三个就能把机器顶到 OOM，而且它们还在写旧版结果
  stale=$(( $(pgrep -f "transcribe.py --mlx-worker" | wc -l) + $(pgrep -f "subtitle-fix.py --shard" | wc -l) ))
  if [ "$stale" -gt 0 ]; then
    say "→ 清掉上一轮残留的 ${stale} 个 worker 进程"
    pkill -9 -f "transcribe.py --mlx-worker" 2>/dev/null
    pkill -9 -f "subtitle-fix.py --shard" 2>/dev/null
    sleep 3
  fi

  # ---------- 1. 转写（whisper large-v3-turbo，GPU）----------
  say "→ 转写一批（≤${ASR_BATCH} 章）"
  python3 tools/transcribe.py --all --jobs 3 --limit "$ASR_BATCH" 2>&1 | tail -3
  asr_done=$(count); left=${asr_done%%/*}; total=$(echo "$asr_done" | tr '/' ' ' | awk '{print $2}')
  [ -n "$total" ] && [ "$left" = "$total" ] && asr_all=1 || asr_all=0

  # ---------- 2. 打包 + 同步，让这一批立刻可听 ----------
  python3 tools/transcribe.py --pack-only 2>&1 | tail -1
  ./sync-transcripts.sh --sim-only 2>&1 | tail -1

  # ---------- 3. 大模型校对（云端 API 优先，兜底本地 Qwen）----------
  if [ "${SKIP_FIX:-0}" = "1" ]; then
    say "→ 按 SKIP_FIX 跳过校对"
  elif [ "$FIX_MODE" = local ] && [ ! -f "$QWEN/model-00001-of-00002.safetensors" ] \
       && [ ! -f "$QWEN/model.safetensors" ]; then
    say "→ 本地校对模型未就绪（$QWEN 还没下完），本轮跳过"
  else
    say "→ 校对一批（$FIX_MODE 后端，≤${FIX_BATCH} 章）"
    "$FIX_PY" tools/subtitle-fix.py --all --limit "$FIX_BATCH" $FIXARGS 2>&1 | tail -3
    python3 tools/transcribe.py --pack-only 2>&1 | tail -1
    ./sync-transcripts.sh --sim-only 2>&1 | tail -1
  fi

  fixed=$(ls tools/transcripts-fix/*/*.json 2>/dev/null | wc -l | tr -d ' ')
  # --check 只统计不加载模型（否则探一次进度就白吃 9GB 内存）；
  # 必须带同一套后端参数：结果标签里含模型名，不带 --api 探到的是本地版的待修数
  fix_todo=$("$FIX_PY" tools/subtitle-fix.py --all --check $FIXARGS 2>/dev/null | grep -oE "待修 [0-9]+" | grep -oE "[0-9]+" || echo "?")
  echo "$(date '+%F %T') 转写 ${left}/${total} · 已纠错 ${fixed} 章 · 待纠错 ${fix_todo} 章" > "$STATUS"
  say "本轮结束：转写 ${left}/${total}，已纠错 ${fixed} 章，待纠错 ${fix_todo} 章"

  # ---------- 4. 两件事都做完了就收工 ----------
  if [ "${asr_all:-0}" = "1" ] && [ "$fix_todo" = "0" ]; then
    say "===== 全部完成：转写与纠错都无剩余章"
    break
  fi
  sleep 15
done
