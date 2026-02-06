cask "cloudmount" do
  version "2.0.0"
  sha256 "PLACEHOLDER_SHA256"

  url "https://github.com/ebreen/cloudmount/releases/download/v#{version}/CloudMount-#{version}.dmg"
  name "CloudMount"
  desc "Mount cloud storage as native macOS volumes via FSKit"
  homepage "https://github.com/ebreen/cloudmount"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "CloudMount.app"

  zap trash: [
    "~/Library/Application Support/com.cloudmount.app",
    "~/Library/Caches/com.cloudmount.app",
    "~/Library/HTTPStorages/com.cloudmount.app",
    "~/Library/Preferences/com.cloudmount.app.plist",
    "~/Library/Saved Application State/com.cloudmount.app.savedState",
  ]

  caveats <<~EOS
    CloudMount requires macOS 26 (Tahoe) or later.

    After installation, enable the FSKit extension:
      System Settings → General → Login Items & Extensions → CloudMount

    Mount a volume:  Use the CloudMount menu bar app, or run: mount -t b2 b2://bucket /mount/point
    Unmount:          Use the menu bar app, or run: diskutil unmount /mount/point

    For help: https://github.com/ebreen/cloudmount
  EOS
end
