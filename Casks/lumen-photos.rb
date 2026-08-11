cask "lumen-photos" do
  version "0.5.18"
  sha256 "0352b8cb1725f8c0ea0f0989322013ba3f058768731793d783aa213a70d99daf"

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
