# Source this file before running rea: `source tools/rea-env.sh`
export PATH="/opt/homebrew/bin:$PATH"
export GHIDRA_INSTALL_DIR="/opt/homebrew/Cellar/ghidra/12.1.4/libexec"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
export ARC_APP="/Applications/Arc.app"
export ARC_BIN="$ARC_APP/Contents/MacOS/Arc"
export ARC_CORE="$ARC_APP/Contents/Frameworks/ArcCore.framework/Versions/A/ArcCore"
export OPEN_RE_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]:-$0}")" rev-parse --show-toplevel 2>/dev/null)/.re"
export OPEN_GHIDRA_DIR="$HOME/Library/Caches/OpenRE/ghidra"
