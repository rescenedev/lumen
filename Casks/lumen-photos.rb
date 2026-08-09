cask "lumen-photos" do
  version "0.5.10"
  sha256 "fd0f66a24623e1c2d791e13f0f7b0705b2a311722a10827980bb6ba38092aadf"

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
