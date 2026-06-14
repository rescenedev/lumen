cask "lumen-photos" do
  version "0.4.1"
  sha256 "91211fb02e954828ab2bd8175416ea4926f913acc95beda04d163f045bb4f64d"

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
