#!/usr/bin/env bash
# threadline-overlay one-line installer.
#
#   curl -fsSL https://…/install.sh | bash
#
# Or from a clone:
#
#   cd overlay && ./install.sh
#
# Builds a release binary, copies it to ~/.local/bin/threadline-overlay,
# writes a LaunchAgent so the daemon survives logout/login, and starts it.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
target_bin="$HOME/.local/bin/threadline-overlay"

# 1. Build.
echo "→ building threadline-overlay (release)…"
(cd "$here" && swift build -c release)

built="$here/.build/release/threadline-overlay"
if [[ ! -x "$built" ]]; then
    echo "build did not produce $built" >&2
    exit 1
fi

# 2. Install via the binary itself (copies to ~/.local/bin and writes plist).
echo "→ installing LaunchAgent…"
"$built" install

# 3. PATH hint.
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
        echo
        echo "→ add ~/.local/bin to your PATH:"
        echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
        ;;
esac

echo
echo "done."
echo "  threadline-overlay show     # show the app window"
echo "  threadline-overlay toggle   # show/hide"
