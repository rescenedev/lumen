cask "lumen-photos" do
  version "0.5.12"
  sha256 "9e8b70826c450fbb874a77b0643a2a3880636a18d7784421ad601bbed4f403f9"

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
