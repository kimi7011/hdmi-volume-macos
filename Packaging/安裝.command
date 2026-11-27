#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/HDMI Volume.app"
driver="$PWD/HDMIVolume.driver"
app_path='/Applications/HDMI Volume.app'
driver_directory='/Library/Audio/Plug-Ins/HAL'
driver_path="$driver_directory/HDMIVolume.driver"

if [[ "$(uname -m)" != arm64 ]]; then
    echo '此版本需要 Apple 晶片 Mac。'
    exit 1
fi
if [[ -e "$app_path" || -e "$driver_path" ]]; then
    echo '已找到 HDMI 音量控制。若要重裝，請先執行同資料夾內的「移除.command」。'
    exit 1
fi
/usr/bin/codesign --verify --strict "$app"
/usr/bin/codesign --verify --strict "$driver"

echo '即將安裝 HDMI 音量控制。macOS 音訊服務會在安裝時短暫重新啟動。'
/usr/bin/sudo -v
driver_installed=0
app_installed=0
done_installing=0
rollback() {
    if [[ "$done_installing" == 1 ]]; then return; fi
    if [[ "$app_installed" == 1 ]]; then /usr/bin/sudo /bin/rm -rf "$app_path"; fi
    if [[ "$driver_installed" == 1 ]]; then
        /usr/bin/sudo /bin/rm -rf "$driver_path"
        /usr/bin/sudo /usr/bin/killall coreaudiod 2>/dev/null || true
    fi
}
trap rollback EXIT
/usr/bin/sudo /bin/mkdir -p "$driver_directory"
driver_installed=1
/usr/bin/sudo /usr/bin/ditto "$driver" "$driver_path"
/usr/bin/sudo /usr/sbin/chown -R root:wheel "$driver_path"
/usr/bin/sudo /usr/bin/killall coreaudiod 2>/dev/null || true

probe="$app/Contents/MacOS/HDMIVolume"
for attempt in {1..12}; do
    if "$probe" --check > /dev/null 2>&1; then break; fi
    if [[ "$attempt" == 12 ]]; then
        echo 'macOS 未載入虛擬音訊裝置。正在還原這次安裝。'
        exit 1
    fi
    sleep 1
done

app_installed=1
/usr/bin/sudo /usr/bin/ditto "$app" "$app_path"
/usr/bin/sudo /usr/sbin/chown -R root:wheel "$app_path"
done_installing=1
echo '已安裝。稍後請從選單列的喇叭圖示選「開始控制 Sony HDMI 音量」。'
/usr/bin/open -a "$app_path"
