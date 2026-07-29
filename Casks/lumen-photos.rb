cask "lumen-photos" do
  version "0.5.5"
  sha256 "922f9742e9bf072c7d0aed45dc6a612c9509def9747a95ac8a352a6f664a1be3"

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
