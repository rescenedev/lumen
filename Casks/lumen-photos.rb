cask "lumen-photos" do
  version "0.5.16"
  sha256 "70061f3c6e5d43e17de2d6ccd1e619957583a7557ee9a057aa5d58a46b40c2e2"

  url "https://github.com/rescenedev/lumen/releases/download/v#{version}/Lumen-#{version}.zip"
  name "Lumen"
  desc "Native macOS photo viewer and manager"
  homepage "https://github.com/rescenedev/lumen"

  app "Lumen.app"

  livecheck do
    url :url
    strategy :github_latest
  end
end
