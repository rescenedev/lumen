cask "lumen-photos" do
  version "0.5.3"
  sha256 "dad8e7df376072c6f246bc64f73ff51fabc508e78a7ab0476d9fbb914fffc231"

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
