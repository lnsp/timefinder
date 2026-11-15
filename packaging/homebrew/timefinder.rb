cask "timefinder" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/lnsp/timefinder/releases/download/v#{version}/TimeFinder-#{version}.zip"
  name "TimeFinder"
  desc "Browse and restore files from Time Machine backups of other Macs"
  homepage "https://github.com/lnsp/timefinder"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "TimeFinder.app"

  zap trash: [
    "~/Library/Caches/tech.espe.TimeFinder",
    "~/Library/Preferences/tech.espe.TimeFinder.plist",
    "~/Library/Saved Application State/tech.espe.TimeFinder.savedState",
  ]

  caveats <<~EOS
    TimeFinder is not notarized by Apple, so macOS blocks its first launch (and the
    first launch after each upgrade). To allow it, open:
      System Settings › Privacy & Security › Open Anyway

    TimeFinder needs Full Disk Access to open Time Machine backups:
      System Settings › Privacy & Security › Full Disk Access
  EOS
end
