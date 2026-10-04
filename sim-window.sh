#!/bin/bash
# 保证「只有一个模拟器窗口」：先回收命令行拉起来的 DeviceHub 残留实例，再保证有且只有一个可见窗口
# 背景：Xcode 27 的设备窗口由 DeviceHub.app 承载。用隐藏方式（open -gj）开的窗口几十秒会自动关，
#       关掉后进程还在但不派发触摸；再补一个 -n 就多一个实例（每个上百 MB），叠起来既费内存又让
#       设备场景掉出前台 —— 表现就是「点了没反应、列表滚不动」。
# 用法：
#   ./sim-window.sh              # 回收残留 + 保证唯一可见窗口（已有就复用）
#   ./sim-window.sh <UDID>       # 指定设备
#   ./sim-window.sh --cleanup    # 只回收命令行拉起的实例，不开窗口
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
# 有没有真窗口要问无障碍树；编译一次缓存起来，避免每次几秒的 swift 解释开销
WINBIN="${TMPDIR:-/tmp}/sonux-hub-windows"
if [ ! -x "$WINBIN" ]; then
    cat > "${WINBIN}.swift" <<'SWIFTEOF'
import ApplicationServices
import Foundation
// 用法：hub-windows <pid>…  逐个打印「pid 窗口数」
for arg in CommandLine.arguments.dropFirst() {
    guard let pid = pid_t(arg) else { continue }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    var v: CFTypeRef?
    let n = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &v) == .success
        ? ((v as? [AXUIElement]) ?? []).count : 0
    print("\(arg) \(n)")
}
SWIFTEOF
    if ! swiftc -O -o "$WINBIN" "${WINBIN}.swift" 2>/dev/null; then rm -f "$WINBIN"; fi
fi

# 某个 pid 是否有可见窗口
hub_windows() { [ -x "$WINBIN" ] && "$WINBIN" "$@" | awk '{s+=$2} END {print s+0}'; }

# 命令行拉起来的实例都带 -CurrentDeviceUDID，IDE 自己起的那个不带 —— 只回收前者，不动 IDE 的窗口
leftovers=$(pgrep -f "MacOS/DeviceHub .*-CurrentDeviceUDID" || true)
if [ -n "$leftovers" ]; then
    echo "回收残留 DeviceHub 实例：$(echo $leftovers | tr '\n' ' ')"
    kill -9 $leftovers 2>/dev/null || true   # DeviceHub 忽略 SIGTERM，必须 -9
    sleep 2
fi

if [ "$CLEANUP_ONLY" = 1 ]; then
    echo "✅ 已清理，当前实例：$(pgrep -f 'MacOS/DeviceHub' | tr '\n' ' ')"
    exit 0
fi

alive=$(pgrep -f "MacOS/DeviceHub" || true)
if [ -n "$alive" ] && [ "$(hub_windows $alive)" -gt 0 ]; then
    echo "✅ 已有可见的设备窗口（pid $(echo $alive | tr '\n' ' ')），直接复用"
    exit 0
fi
if [ -n "$alive" ]; then
    # 进程在但窗口没了：这种僵尸窗口宿主会抢设备的场景归属，留着就会「点了没反应」，一律回收
    echo "设备窗口已全部关闭，回收空转实例：$(echo $alive | tr '\n' ' ')"
    kill -9 $alive 2>/dev/null || true
    sleep 2
fi

echo "🖥  打开设备窗口 $UDID …"
open -n -a "$HUB" --args -CurrentDeviceUDID "$UDID"
sleep 5
pids=$(pgrep -f "MacOS/DeviceHub" || true)
echo "✅ 实例 $(echo $pids | wc -w | tr -d ' ') 个（pid $(echo $pids | tr '\n' ' ')），可见窗口 $(hub_windows $pids) 个"
