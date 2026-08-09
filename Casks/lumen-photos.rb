cask "lumen-photos" do
  version "0.5.8"
  sha256 "aa726ea09e526676b2361e66c2fccaee07f6c2ac4da7fbfa1f19fd4eca2a48fe"

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
