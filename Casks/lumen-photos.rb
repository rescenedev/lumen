cask "lumen-photos" do
  version "0.5.17"
  sha256 "98114cf35418dedfc406a3e688cac1b6e187c624185ca88b443364ecd859f889"

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
