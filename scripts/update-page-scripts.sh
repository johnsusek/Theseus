#!/bin/zsh
# Rebuilds the page scripts the browser injects from the SafariPilot checkout and copies them into App/Browser.
set -euo pipefail

root="${0:A:h:h}"
pilot="${SAFARIPILOT:-$HOME/Code/SafariPilot}"

(cd "$pilot/web" && npm run build)
cp "$pilot/build/webview/content.js" "$root/App/Browser/page-content.js"
cp "$pilot/extension/main.js" "$root/App/Browser/page-main.js"
echo "copied page scripts from $pilot at $(git -C "$pilot" rev-parse --short HEAD)"
