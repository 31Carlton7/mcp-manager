cask "mcp-manager" do
  # The release workflow rewrites these two lines from the tag and the built DMG's checksum, so
  # the placeholders below are only ever what a fresh clone starts with.
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/carltonaikins/mcp-manager/releases/download/v#{version}/MCPManager-#{version}.dmg"
  name "MCP Manager"
  desc "One library of MCP servers, synced into every MCP client on your Mac"
  homepage "https://github.com/carltonaikins/mcp-manager"

  depends_on macos: ">= :tahoe"

  app "MCPManager.app"

  uninstall launchctl: "co.charmtechnologies.mcpmd",
            quit:      "co.charmtechnologies.mcpmanager"

  zap trash: [
    "~/.mcpm",
    "~/Library/Caches/co.charmtechnologies.mcpmanager",
  ]
end
