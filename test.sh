#!/bin/bash
# 在 iOS 模拟器上编译并跑一遍 Sonux 的单元测试，最后打印逐文件的行覆盖率摘要。
#
# 用法：
#   ./test.sh                       # 用当前 booted 的模拟器；没开就用第一台 iPhone
#   ./test.sh <UDID>                # 指定设备
#   ./test.sh --coverage            # 只跑测试并输出覆盖率报告
#
# 依赖：仓库根目录要有 Sonux.xcodeproj（由 xcodegen 从 project.yml 生成）。
set -euo pipefail
cd "$(dirname "$0")"

COVERAGE_ONLY=0
UDID=""
for arg in "$@"; do
  case "$arg" in
    --coverage) COVERAGE_ONLY=1 ;;
    --*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) UDID="$arg" ;;
  esac
done

# 没传 UDID 就先找一个 booted 的 iPhone；没有 booted 就用 simctl 列表里的第一台可用 iPhone
if [[ -z "$UDID" ]]; then
  UDID=$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
d = json.load(sys.stdin)
for runtime, devs in d["devices"].items():
    for dev in devs:
        if dev.get("state") == "Booted" and dev.get("isAvailable") and "iPhone" in dev["name"]:
            print(dev["udid"]); sys.exit()
') || true
  if [[ -z "$UDID" ]]; then
    UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)
for runtime, devs in sorted(d["devices"].items(), reverse=True):
    if "iOS" not in runtime: continue
    for dev in devs:
        if dev.get("isAvailable") and "iPhone" in dev["name"]:
            print(dev["udid"]); sys.exit()
')
  fi
fi

if [[ -z "$UDID" ]]; then
  echo "找不到可用的 iPhone 模拟器；先运行 ./sim-window.sh 或 xcrun simctl boot <UDID>" >&2
  exit 1
fi
echo "使用模拟器 UDID: $UDID"

DEST="platform=iOS Simulator,id=$UDID"
RESULT_PATH="build/Logs/Test/latest.xcresult"

# build-for-testing 会把产物留在 build/，之后 test-without-building 就能秒跑
xcodebuild build-for-testing \
  -project Sonux.xcodeproj -scheme Sonux \
  -destination "$DEST" \
  -derivedDataPath build \
  -quiet

rm -rf "$RESULT_PATH"
xcodebuild test-without-building \
  -project Sonux.xcodeproj -scheme Sonux \
  -destination "$DEST" \
  -derivedDataPath build \
  -resultBundlePath "$RESULT_PATH" \
  | grep -E "Test Suite '(All tests|.*\.xctest)'|Executed [0-9]+ tests|\*\* TEST"

if [[ $COVERAGE_ONLY -eq 1 || $# -gt 0 ]]; then
  xcrun xccov view --report --only-targets "$RESULT_PATH"
fi
