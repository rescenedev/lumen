cask "lumen-photos" do
  version "0.5.4"
  sha256 "7bd35008825bf0cde1e27550394cfbb7cb0613c13d613d1e1773f360e64cf287"

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
