cask "lumen-photos" do
  version "0.5.6"
  sha256 "29fdd6b5baf8939c397324757f4196bb7541ef067b17461d8dba24a1e7d100cd"

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
