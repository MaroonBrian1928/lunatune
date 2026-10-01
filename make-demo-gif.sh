#!/bin/bash
# Regenerate assets/demo.gif from `lunatune --demo`.
# Needs: brew install asciinema agg && brew install --cask font-jetbrains-mono-nerd-font
set -euo pipefail
cd "$(dirname "$0")"
cast=$(mktemp -t lunatune-demo).cast
asciinema rec --headless --overwrite --window-size 110x40 --command \
    'env TERM=xterm-256color TERM_PROGRAM=ghostty COLORTERM=truecolor COLUMNS=110 LINES=40 bash -c "printf \"\\033[38;5;111m❯\\033[0m lunatune --demo\\n\"; sleep 0.6; ./lunatune.sh --demo; sleep 1.5"' \
    "$cast"
agg --font-family "JetBrainsMono Nerd Font Mono,Apple Color Emoji" --font-size 18 \
    --fps-cap 24 --idle-time-limit 3 --last-frame-duration 4 \
    --theme "0e0c1b,d6d8f0,1b1830,f38ba8,a6e3a1,f9e2af,89b4fa,cba6f7,94e2d5,bac2de,45475a,f38ba8,a6e3a1,f9e2af,89b4fa,cba6f7,94e2d5,ffffff" \
    "$cast" assets/demo.gif
rm -f "$cast"
echo "wrote assets/demo.gif"
