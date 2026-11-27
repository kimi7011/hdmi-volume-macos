cask "hdmi-volume" do
  version "0.2.3"
  sha256 "664cbe9be638b2768fbec66477615e2da9e2b4ef39bac22d387f202535c8b8b1"

  revision = "93f6c28227d27f8edf7322bffa33091d1a449aa1"
  source = "hdmi-volume-macos-#{revision}"

  url "https://github.com/kimi7011/hdmi-volume-macos/archive/#{revision}.tar.gz"
  name "HDMI Volume"
  desc "Menu bar volume control for Sony HDMI TVs"
  homepage "https://github.com/kimi7011/hdmi-volume-macos"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  installer script: "#{source}/Packaging/install-homebrew.sh"

  uninstall script: "#{source}/Packaging/移除.command"

  caveats <<~EOS
    Open HDMI Volume from Applications and select「開始控制 Sony HDMI 音量」in the menu bar.
  EOS
end
