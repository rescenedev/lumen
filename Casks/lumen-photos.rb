cask "lumen-photos" do
  version "0.5.11"
  sha256 "2707686c36670d03790e10f7ed5c8c2bea02398ae33443ba5e59f4c6da64378d"

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
