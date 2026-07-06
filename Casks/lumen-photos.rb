cask "lumen-photos" do
  version "0.5.1"
  sha256 "4018170a15eaa89ce09dca7ebb64627c9f8ed9877668e384f7f8f5d4bdacc69b"

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
