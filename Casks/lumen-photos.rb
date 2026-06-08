cask "lumen-photos" do
  version "0.2.0"
  sha256 "bc69576172465ab022e6ee1444e585362dcdfbbb3379ae461afdc78dc737b820"

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
