#!/bin/sh
# Installs Routi Core on this Mac and keeps it running.
#
# Run from inside an unpacked Routi Core folder. Puts nothing anywhere except:
#   ~/.routi/                  data (bots, conversations, keys stay in the Keychain)
#   ~/Library/LaunchAgents/   one agent that starts the core at login
# Needs Homebrew for Node if Node 22+ is not already here. Safe to run again.
set -e

here="$(cd "$(dirname "$0")/.." && pwd)"
label="com.narralabs.routid"
agent="$HOME/Library/LaunchAgents/$label.plist"
logs="$HOME/.routi/logs"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

say "Checking Node"
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Routi Core needs Node 22 or newer. Install Homebrew from https://brew.sh, then run this again." >&2
    exit 1
  fi
  brew install node@22
  brew link --overwrite --force node@22
fi
node --version

say "Checking pnpm"
command -v pnpm >/dev/null 2>&1 || corepack enable pnpm 2>/dev/null || npm install -g pnpm
pnpm --version

say "Installing and building"
cd "$here"
pnpm install --frozen-lockfile
pnpm --filter @routi/protocol build
pnpm --filter routid build

say "Installing the login agent"
mkdir -p "$logs" "$HOME/Library/LaunchAgents"
node_bin="$(command -v node)"
cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$node_bin</string>
    <string>$here/daemon/dist/src/index.js</string>
  </array>
  <key>WorkingDirectory</key><string>$here/daemon</string>
  <key>EnvironmentVariables</key><dict>
    <!-- The vendor CLIs live here: Claude Code from npm, Grok in ~/.grok/bin. -->
    <key>PATH</key><string>$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$logs/routid.log</string>
  <key>StandardErrorPath</key><string>$logs/routid.log</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent"

say "Waiting for the core"
for _ in $(seq 1 20); do
  if curl -fs http://127.0.0.1:7171/ >/dev/null 2>&1; then
    echo "Routi Core is running on port 7171 and will start at login."
    echo "Open the Routi app. Logs: $logs/routid.log"
    exit 0
  fi
  sleep 1
done
echo "The core did not answer. See $logs/routid.log" >&2
exit 1
