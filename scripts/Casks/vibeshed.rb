cask "vibeshed" do
  version "0.15.0"
  sha256 "6f6207fc555259b0b5e3e9d10a682afb81da20d0cc6c1d9072eefbc4246e3045"

  url "https://github.com/vibeshed/vibeshed/releases/download/v#{version}/Vibeshed-#{version}.zip"
  name "Vibeshed"
  desc "Keyboard-driven launcher"
  homepage "https://vibeshed.dev"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Vibeshed.app"

  zap trash: [
    "~/.config/vibeshed",
    "~/Library/Application Support/com.ivandmitriev.Vibeshed",
    "~/Library/Caches/com.ivandmitriev.Vibeshed",
    "~/Library/Preferences/com.ivandmitriev.Vibeshed.plist",
    "~/Library/Saved Application State/com.ivandmitriev.Vibeshed.savedState",
  ]
end
