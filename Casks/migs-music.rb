cask "migs-music" do
  version "0.1.0"
  sha256 "REPLACE_ME_AFTER_RELEASE"

  # GitHub Releases pattern. Update after running `release.sh <version>` and uploading the
  # produced dist/migs-music-<version>.dmg. Replace REPLACE_ME with the SHA256 from
  # dist/migs-music-<version>.dmg.sha256.
  url "https://github.com/michaelhball/migs-music-mac/releases/download/v#{version}/migs-music-#{version}.dmg"

  name "migs music"
  desc "Menu-bar app that syncs Apple Music playlists to migs music on Android"
  homepage "https://github.com/michaelhball/migs-music-mac"

  app "MigsMusicMac.app"

  # Auto-update check is best-effort — we publish via GitHub Releases, brew checks the
  # latest tag and compares the version line above.
  livecheck do
    url :url
    strategy :github_latest
  end

  zap trash: [
    "~/Library/Application Support/MigsMusicMac",
    "~/Library/Caches/com.migsmusic.mac",
    "~/Library/Preferences/com.migsmusic.mac.plist",
  ]
end
