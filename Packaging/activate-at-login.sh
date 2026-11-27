#!/bin/bash
set -euo pipefail

contents=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
app=${contents%/Contents}
binary="$contents/MacOS/HDMIVolume"
driver='/Library/Audio/Plug-Ins/HAL/HDMIVolume.driver'
account=$(/usr/bin/id -un)
log_directory="$HOME/Library/Logs/HDMI Volume"
app_log="$log_directory/login-app.log"

/bin/mkdir -p "$log_directory"
exec > "$log_directory/login.log" 2>&1
printf '登入啟動 %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')"

recovery_running() {
    local command
    while IFS= read -r command; do
        if [[ "$command" == "$binary --recover "* ]]; then return 0; fi
    done < <(/bin/ps -xww -U "$account" -o command=)
    return 1
}

route_active() {
    [[ "$1" == *'media: HDMI 音量控制'* && "$1" == *'alerts: HDMI 音量控制'* ]] && recovery_running
}

# Login can precede the HDMI audio device. Poll at a bounded rate so TVs
# powered on later still activate without a second app instance.
delay=2
restored=0
while [[ -x "$binary" && -d "$driver" ]]; do
    if [[ "$(/usr/bin/stat -f %Su /dev/console)" == "$account" ]]; then
        state=$("$binary" --check 2>/dev/null) || state=''
        if [[ "$state" == *'media: HDMI 音量控制'* || "$state" == *'alerts: HDMI 音量控制'* ]]; then
            if recovery_running; then
                printf '%s\n' 'Sony HDMI 音量控制已啟用。'
                exit 0
            fi
            if [[ "$restored" == 0 ]]; then
                restored=1
                "$binary" --recover-login-route
                continue
            fi
        fi
        if [[ "$state" == *'Sony HDMI: '* ]]; then break; fi
    fi
    /bin/sleep "$delay"
    if [[ "$delay" -lt 10 ]]; then delay=$((delay + 2)); fi
done

if [[ ! -x "$binary" || ! -d "$driver" ]]; then exit 0; fi
: > "$app_log"
/usr/bin/open -g -a "$app" --stderr "$app_log" --args --activate-at-login

for ((attempt = 1; attempt <= 30; attempt++)); do
    state=$("$binary" --check 2>/dev/null) || state=''
    if route_active "$state" && /usr/bin/grep -Fxq 'HDMI route active' "$app_log"; then
        printf '%s\n' 'Sony HDMI 音量控制已啟用。'
        exit 0
    fi
    /bin/sleep 1
done
printf '%s\n' '登入啟動檢查未觀察到 Sony HDMI 音量控制。'
exit 1
