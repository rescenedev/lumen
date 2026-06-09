cask "lumen-photos" do
  version "0.3.2"
  sha256 "64463159c93d61edcd80e13a533cdf1e22bc37701afed7fbf36e6cf1a96937d9"

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
