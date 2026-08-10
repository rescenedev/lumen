cask "lumen-photos" do
  version "0.5.14"
  sha256 "5d2111b09ffbf3379fe17855346e9ddaeb4b1ea6bdfe517330e0cfd289deb631"

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
