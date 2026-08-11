cask "lumen-photos" do
  version "0.5.15"
  sha256 "bd447d18d60b47d13dc07157e9923df30f106227744128d4a73894c4f553324f"

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
