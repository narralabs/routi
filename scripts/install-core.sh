#!/bin/sh
# Installs Routi Core on this Mac and keeps it running.
#
# Run from inside an unpacked Routi Core folder. Puts things in exactly two places:
#   ~/.routi/                  data, and Node if this Mac has none
#   ~/Library/LaunchAgents/    one agent that starts the core at login
# Nothing is installed globally — no Homebrew, no npm -g. Safe to run again.
set -e

here="$(cd "$(dirname "$0")/.." && pwd)"
label="com.narralabs.routid"
agent="$HOME/Library/LaunchAgents/$label.plist"
logs="$HOME/.routi/logs"
node_version="22.21.0"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Node 22+ already here is used as is; otherwise the official build is fetched into
# ~/.routi/node, which is what the good installers do rather than asking a person to
# install a runtime first.
say "Checking Node"
node_bin=""
if command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
  node_bin="$(command -v node)"
elif [ -x "$HOME/.routi/node/bin/node" ]; then
  node_bin="$HOME/.routi/node/bin/node"
else
  case "$(uname -m)" in arm64) arch="arm64" ;; x86_64) arch="x64" ;; *) echo "Unsupported Mac: $(uname -m)" >&2; exit 1 ;; esac
  url="https://nodejs.org/dist/v$node_version/node-v$node_version-darwin-$arch.tar.gz"
  echo "Fetching Node $node_version for $arch"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/node.tar.gz"
  rm -rf "$HOME/.routi/node"; mkdir -p "$HOME/.routi/node"
  tar xzf "$tmp/node.tar.gz" -C "$HOME/.routi/node" --strip-components=1
  rm -rf "$tmp"
  node_bin="$HOME/.routi/node/bin/node"
fi
node_dir="$(dirname "$node_bin")"
# corepack's shim is `#!/usr/bin/env node`, so the Node in use must be first on PATH.
export PATH="$node_dir:$PATH"
"$node_bin" --version

say "Installing and building"
cd "$here"
# corepack ships with Node and runs the pnpm version package.json pins — the same one
# every other install path uses.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
pnpm="$node_dir/corepack pnpm"
$pnpm install --frozen-lockfile
$pnpm --filter @routi/protocol build
$pnpm --filter routid build

if [ -n "$ROUTI_INSTALL_NO_AGENT" ]; then
  echo "Built. Skipping the login agent (ROUTI_INSTALL_NO_AGENT is set)."
  exit 0
fi

say "Installing the login agent"
mkdir -p "$logs" "$HOME/Library/LaunchAgents"
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
    <!-- Grok's CLI lives in ~/.grok/bin; Claude Code and Codex ship with the core. -->
    <key>PATH</key><string>$node_dir:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
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
  if curl -fs http://127.0.0.1:7171/health >/dev/null 2>&1; then
    echo "Routi Core is running and will start at login. Open the Routi app."
    echo "Logs: $logs/routid.log"
    exit 0
  fi
  sleep 1
done
echo "The core did not answer. See $logs/routid.log" >&2
exit 1
