#!/bin/bash
# 保证「只有一个模拟器窗口」：先回收命令行拉起来的 DeviceHub 残留实例，再开一个可见窗口
# 背景：Xcode 27 的设备窗口由 DeviceHub.app 承载，命令行 `open -n` 每调一次就多一个实例，
#       每个实例常驻上百 MB；而且用隐藏方式（open -gj）开的窗口几十秒会自动关，于是越补越多。
# 用法：
#   ./sim-window.sh              # 回收残留 + 给已 booted 的设备开唯一窗口
#   ./sim-window.sh <UDID>       # 指定设备
#   ./sim-window.sh --cleanup    # 只回收，不开窗口（收尾用）
set -u

CLEANUP_ONLY=0
if [ "${1:-}" = "--cleanup" ]; then CLEANUP_ONLY=1; shift; fi

UDID="${1:-}"
if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
fi
if [ -z "$UDID" ]; then
    echo "❌ 没有已 booted 的模拟器，先跑 xcrun simctl boot <UDID>"
    exit 1
fi

HUB="/Applications/Xcode.app/Contents/Applications/DeviceHub.app"

# 只回收带 -CurrentDeviceUDID 的（命令行自动化拉起的），IDE 自己起的实例不动。
# 注意：DeviceHub 忽略 SIGTERM，必须 -9；被杀的若是没有窗口的实例，设备与 App 都不受影响。
leftovers=$(pgrep -f "MacOS/DeviceHub .*-CurrentDeviceUDID" || true)
if [ -n "$leftovers" ]; then
    echo "回收残留 DeviceHub 实例：$(echo $leftovers | tr '\n' ' ')"
    kill -9 $leftovers 2>/dev/null || true
    sleep 2
fi

if [ "$CLEANUP_ONLY" = 1 ]; then
    echo "✅ 已清理，当前实例：$(pgrep -f 'MacOS/DeviceHub' | tr '\n' ' ')"
    exit 0
fi

echo "🖥  打开设备窗口 $UDID …"
open -n -a "$HUB" --args -CurrentDeviceUDID "$UDID"
sleep 4

pids=$(pgrep -f "MacOS/DeviceHub" || true)
count=$(echo $pids | wc -w | tr -d ' ')
echo "✅ 当前 DeviceHub 实例：$count 个（pid $(echo $pids | tr '\n' ' ')）"
if [ "$count" -gt 1 ]; then
    echo "⚠️  多于一个，说明还有别的来源在拉窗口，可再跑 ./sim-window.sh --cleanup"
fi
