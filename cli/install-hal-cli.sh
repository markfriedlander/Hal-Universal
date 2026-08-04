#!/usr/bin/env bash
#
# install-hal-cli.sh - put the `hal` terminal command on your PATH.
#
# This is the manual installer for the Lab's `hal` CLI (tools/hal). Eventually the
# Hal app installs its own command from a Lab button; until then, run this once.
#
#   ./tools/install-hal-cli.sh              # installs to ~/.local/bin
#   ./tools/install-hal-cli.sh /usr/local/bin
#
# After install: `hal help`, `hal "hi Hal"`, or just `hal` for an interactive chat.
# Config (host/port/token) comes from env vars or ~/.config/hal/config.json; see
# the header of tools/hal.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/hal"
DEST_DIR="${1:-$HOME/.local/bin}"

if [ ! -f "$SRC" ]; then
  echo "error: cannot find the hal script next to this installer ($SRC)" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST_DIR/hal"
chmod +x "$DEST_DIR/hal"
echo "Installed hal to $DEST_DIR/hal"

case ":$PATH:" in
  *":$DEST_DIR:"*)
    echo "$DEST_DIR is already on your PATH. Try:  hal help"
    ;;
  *)
    echo
    echo "NOTE: $DEST_DIR is not on your PATH yet. Add this line to your shell profile"
    echo "(~/.zshrc for zsh), then open a new terminal:"
    echo
    echo "    export PATH=\"$DEST_DIR:\$PATH\""
    ;;
esac
