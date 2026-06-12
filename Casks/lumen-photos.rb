cask "lumen-photos" do
  version "0.4.0"
  sha256 "fd23d76705a1a6d2d339c72c11f31a36c9e89e16d4338acf926c27a891fe5623"

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
