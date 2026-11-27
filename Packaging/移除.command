#!/bin/bash
set -euo pipefail
app_path='/Applications/HDMI Volume.app'
driver_path='/Library/Audio/Plug-Ins/HAL/HDMIVolume.driver'
if [[ ! -e "$app_path" && ! -e "$driver_path" ]]; then
    echo '找不到已安裝的 HDMI 音量控制。'
    exit 0
fi

echo '即將移除 HDMI 音量控制。macOS 音訊服務會短暫重新啟動。'
/usr/bin/sudo -v
# Remove this app's user login job before stopping the audio route.
login_service="gui/$(id -u)/local.hdmivolume.login"
login_plist="$HOME/Library/LaunchAgents/local.hdmivolume.login.plist"
if /bin/launchctl print "$login_service" >/dev/null 2>&1; then
    /bin/launchctl bootout "$login_service"
fi
if [[ -f "$login_plist" ]]; then /bin/rm "$login_plist"; fi

# The recovery process stays alive until the main app has released the route.
app_pattern='^/Applications/HDMI Volume[.]app/Contents/MacOS/HDMIVolume($| --activate-at-login( --request-keyboard-access)?$| --test-output [^ ]+$)'
if /usr/bin/pgrep -f "$app_pattern" >/dev/null; then
    /usr/bin/pkill -TERM -f "$app_pattern" || true
    for attempt in {1..10}; do
        if ! /usr/bin/pgrep -f "$app_pattern" >/dev/null; then break; fi
        if [[ "$attempt" == 10 ]]; then
            echo '工具仍在執行。請在選單列結束工具後再次執行移除。'
            exit 1
        fi
        sleep 1
    done
fi

/usr/bin/sudo /bin/rm -rf "$driver_path" "$app_path"
/usr/bin/sudo /usr/bin/killall coreaudiod 2>/dev/null || true
echo '已移除 HDMI 音量控制。'
