cask "lumen-photos" do
  version "0.5.2"
  sha256 "ac837ae06674d5875616e0654f649c444e0c8fcfc567fa02c4e7e564283bddf7"

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
