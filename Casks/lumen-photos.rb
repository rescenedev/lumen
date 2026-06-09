cask "lumen-photos" do
  version "0.3.1"
  sha256 "7d95c8a8f3942bbdccf4eaf8f4c329cd755e75e57b1a60db6c3368e9e3b1ff03"

  url "https://github.com/rescenedev/lumen/releases/download/v#{version}/Lumen-#{version}.zip"
  name "Lumen"
  desc "Native macOS photo viewer and manager"
  homepage "https://github.com/rescenedev/lumen"

  app "Lumen.app"

  livecheck do
    url :url
    strategy :github_latest
  end

  caveats <<~EOS
    Lumen is ad-hoc signed (not notarized). If macOS blocks it on first launch,
    either right-click the app and choose Open, or clear the quarantine flag:
      xattr -dr com.apple.quarantine "/Applications/Lumen.app"
  EOS
end
