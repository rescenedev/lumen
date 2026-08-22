cask "lumen-photos" do
  version "0.5.19"
  sha256 "bbe8e2578025e40f98e1bb5229b96d9858ebe8b81d2508b5fe977b1e8cc3a298"

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
