cask "lumen-photos" do
  version "0.5.7"
  sha256 "524f6cb89b0eb2438176e4be7b87089f164d7c3c3aa697e15363b2ad1787c028"

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
