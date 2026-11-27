# HDMI 音量控制

在 macOS 選單列啟用 HDMI 音量控制後，可以用控制中心調整 Sony HDMI 電視的音量。支援 Apple 晶片 Mac，需 macOS 14.2 以上。

## Homebrew 安裝

Homebrew 會在本機建置，需安裝含 macOS 26 或更新 SDK 的 Xcode Command Line Tools。若先前使用手動安裝，請先執行原安裝資料夾內的「移除.command」。

```sh
brew tap kimi7011/hdmi-volume-macos https://github.com/kimi7011/hdmi-volume-macos.git
brew install --cask kimi7011/hdmi-volume-macos/hdmi-volume
```

安裝需要管理員授權，並會短暫重新啟動 macOS 音訊服務。安裝後從「應用程式」打開 HDMI Volume。移除指令如下。

```sh
brew uninstall --cask kimi7011/hdmi-volume-macos/hdmi-volume
```

## 使用

從選單列的喇叭圖示選「開始控制 Sony HDMI 音量」。首次使用時，請允許擷取系統音訊。選「停止並恢復音訊」可切回原本的輸出。

## 手動建置與安裝

使用含 macOS 26 或更新 SDK 的 Xcode Command Line Tools，在專案目錄執行：

```sh
./build.sh
./dist/安裝.command
```

更新或移除時先執行 `./dist/移除.command`。

## 授權

[Apache License 2.0](LICENSE)。驅動程式來源與修改見 [Driver/NOTICE.md](Driver/NOTICE.md)。
