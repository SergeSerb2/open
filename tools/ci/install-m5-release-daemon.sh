#!/usr/bin/env bash
# Install/update the M5 macOS Aqua LaunchAgent (`com.serge.open-release`) that
# runs tools/ci/release-daemon.py inside gui/<uid> (no persistent self-hosted
# GitHub Actions runner attached to the public SergeSerb2/open repo).
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "This installer runs on macOS only." >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAEMON_DIR="$HOME/.local/share/open-release-daemon"
LOG_DIR="$HOME/Library/Logs/com.serge.open-release"
WORKTREE="${OPEN_RELEASE_WORKTREE:-$HOME/Developer/open-release-worktree}"
PLIST="$HOME/Library/LaunchAgents/com.serge.open-release.plist"

mkdir -p "$DAEMON_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
install -m 755 "$ROOT/tools/ci/release-daemon.py" "$DAEMON_DIR/release-daemon.py"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.serge.open-release</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/bin/python3</string>
      <string>${DAEMON_DIR}/release-daemon.py</string>
      <string>--worktree</string>
      <string>${WORKTREE}</string>
      <string>--state-dir</string>
      <string>${DAEMON_DIR}</string>
      <string>--no-cancel-phase</string>
      <string>09-dmg</string>
      <string>--poll-seconds</string>
      <string>15</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${DAEMON_DIR}</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ExitTimeOut</key>
    <integer>120</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>PATH</key>
      <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
      <key>OPEN_ENGINE_ROOT</key>
      <string>${HOME}/Developer/open-engine</string>
      <key>OPEN_BUILD_JOBS</key>
      <string>6</string>
    </dict>
  </dict>
</plist>
EOF
chmod 644 "$PLIST"

UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/com.serge.open-release" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"
launchctl kickstart -k "gui/${UID_NUM}/com.serge.open-release"
sleep 2
launchctl print "gui/${UID_NUM}/com.serge.open-release" | grep -E "state =|pid =|domain =" | head -n 6
echo "Installed and started com.serge.open-release (logs: $LOG_DIR/stdout.log)"
