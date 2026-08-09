cask "lumen-photos" do
  version "0.5.13"
  sha256 "0210ab4cd1c1c86696ff7fee6b6d70388173a0766e5844ecc3b33be280d1a6d6"

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
