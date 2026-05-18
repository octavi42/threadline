#!/usr/bin/env bash
# threadline-overlay installer.
#
# One-liner (prebuilt release when available, else clone + build):
#
#   curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
#
# From a clone:
#
#   cd overlay && ./install.sh
#
# Copies to ~/.local/bin/threadline-overlay, writes a LaunchAgent, and starts it.

set -euo pipefail

REPO_URL="${THREADLINE_INSTALL_REPO:-https://github.com/octavi42/threadline.git}"
REPO_REF="${THREADLINE_INSTALL_REF:-main}"
GITHUB_REPO="${THREADLINE_GITHUB_REPO:-octavi42/threadline}"

path_hint() {
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *)
            echo
            echo "→ add ~/.local/bin to your PATH:"
            echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
            ;;
    esac
}

finish() {
    path_hint
    echo
    echo "done."
    echo "  threadline-overlay show     # show the app window"
    echo "  threadline-overlay toggle   # show/hide (⌃⌥⌘T)"
}

macos_arch() {
    case "$(uname -m)" in
        arm64)  echo arm64 ;;
        x86_64) echo x86_64 ;;
        *)      return 1 ;;
    esac
}

release_api_url() {
    if [[ -n "${THREADLINE_VERSION:-}" ]]; then
        echo "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${THREADLINE_VERSION}"
    else
        echo "https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    fi
}

install_from_prebuilt() {
    local arch asset api url tmp binary
    arch=$(macos_arch) || return 1
    asset="threadline-overlay-macos-${arch}.tar.gz"
    api=$(release_api_url)

    url=$(curl -fsSL "$api" | python3 -c "
import json, sys
asset = sys.argv[1]
data = json.load(sys.stdin)
for a in data.get('assets', []):
    if a.get('name') == asset:
        print(a['browser_download_url'])
        break
" "$asset") || return 1

    if [[ -z "$url" ]]; then
        return 1
    fi

    echo "→ installing prebuilt ${asset}…"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL "$url" | tar -xzf - -C "$tmp"
    binary="$tmp/threadline-overlay"
    if [[ ! -x "$binary" ]]; then
        echo "archive did not contain threadline-overlay" >&2
        return 1
    fi
    "$binary" install
}

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

install_from_source() {
    local here built
    here=$(resolve_overlay_dir)

    echo "→ building threadline-overlay (release)…"
    (cd "$here" && swift build -c release)

    built="$here/.build/release/threadline-overlay"
    if [[ ! -x "$built" ]]; then
        echo "build did not produce $built" >&2
        exit 1
    fi

    echo "→ installing LaunchAgent…"
    "$built" install
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "threadline-overlay requires macOS" >&2
    exit 1
fi

if [[ "${THREADLINE_BUILD_FROM_SOURCE:-}" == "1" ]]; then
    install_from_source
elif install_from_prebuilt; then
    :
else
    echo "→ no prebuilt release for this Mac; building from source…"
    install_from_source
fi

finish
