#!/bin/zsh
# Builds Debug against the ClaudeEngine checkout beside this one, replaces /Applications/Theseus.app, and relaunches it.
set -euo pipefail

root="${0:A:h:h}"
derived="$root/build/DerivedData"
app="$derived/Build/Products/Debug/Theseus.app"
installed="/Applications/Theseus.app"

cd "$root"
rm -rf "$app"
xcodegen generate --quiet
mkdir -p "$derived" build/Dev.xcworkspace
# Local packages in the workspace take the place of the GitHub ones, so engine and stagehand edits build without a push.
cat >build/Dev.xcworkspace/contents.xcworkspacedata <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="group:../Theseus.xcodeproj"></FileRef>
  <FileRef location="group:../../ClaudeEngine"></FileRef>
  <FileRef location="group:../../../stagehand"></FileRef>
</Workspace>
XML
# A failed build can leave a partial bundle behind, so gate on xcodebuild's status rather than the bundle existing.
if ! xcodebuild -workspace build/Dev.xcworkspace -scheme Theseus -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived" -allowProvisioningUpdates build >"$derived/build.log" 2>&1; then
  grep -E " error:" "$derived/build.log" >&2 || true
  echo "build failed, see $derived/build.log" >&2
  exit 1
fi

pkill -U "$(id -u)" -x Theseus 2>/dev/null || true
# Opening the app while the old copy is still quitting fails with error -600.
while pgrep -U "$(id -u)" -x Theseus >/dev/null; do sleep 0.1; done
rm -rf "$installed"
ditto "$app" "$installed"
open "$installed"
echo "installed $installed"
