cask "lumen-photos" do
  version "0.5.9"
  sha256 "31c567382af442536d19700b1657cc520a4e97763d4ee4e68be1f4f3a6bd27b7"

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
