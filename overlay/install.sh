#!/usr/bin/env bash
# threadline-overlay installer.
#
# One-liner (downloads script, clones repo, builds):
#
#   curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
#
# From a clone:
#
#   cd overlay && ./install.sh
#
# Builds a release binary, copies it to ~/.local/bin/threadline-overlay,
# writes a LaunchAgent so the daemon survives logout/login, and starts it.

set -euo pipefail

REPO_URL="${THREADLINE_INSTALL_REPO:-https://github.com/octavi42/threadline.git}"
REPO_REF="${THREADLINE_INSTALL_REF:-main}"

resolve_overlay_dir() {
    local script="${BASH_SOURCE[0]:-${0:-}}"
    if [[ -n "$script" ]] && [[ "$script" != bash ]] && [[ "$script" != -bash ]] && [[ -f "$script" ]]; then
        cd "$(dirname "$script")" && pwd
        return
    fi

    echo "→ fetching Threadline source…"
    local work
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$work/threadline"
    echo "$work/threadline/overlay"
}

here=$(resolve_overlay_dir)
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
echo "  threadline-overlay toggle   # show/hide (⌃⌥⌘T)"
