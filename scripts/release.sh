#!/bin/zsh
# Usage: scripts/release.sh X.Y.Z [--no-publish]
# Builds a Developer ID signed, notarized and stapled DMG at that version against the ClaudeEngine release that project.yml pins,
# then commits the version bump, tags vX.Y.Z, pushes, and publishes a GitHub release with docs/releases/X.Y.Z.md as its notes.
# --no-publish stops after the DMG and puts project.yml back. Notary credentials come from the SafariPilot profile (or $NOTARY_PROFILE).
set -euo pipefail

version=${1:?usage: scripts/release.sh X.Y.Z [--no-publish]}
publish=1
[[ ${2:-} == --no-publish ]] && publish=0
root="${0:A:h:h}"
profile=${NOTARY_PROFILE:-SafariPilot}
out="$root/build/release"
derived="$root/build/ReleaseData"
archive="$out/Theseus.xcarchive"
app="$out/export/Theseus.app"
dmg="$out/Theseus-$version.dmg"
notes="docs/releases/$version.md"

fail() { echo "$1" >&2; exit 1; }

cd "$root"
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "version must be X.Y.Z"
[[ $(git branch --show-current) == main ]] || fail "release from main"
git diff --quiet HEAD || fail "commit or stash tracked changes first"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "tag v$version already exists"
git cat-file -e "HEAD:$notes" 2>/dev/null || fail "commit release notes at $notes first"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || fail "no notary credentials: run xcrun notarytool store-credentials $profile"

# Put project.yml back unless the release commit took it.
trap 'git checkout -q HEAD -- project.yml' EXIT
build=$(( $(git rev-list --count HEAD) + 1 ))
sed -i '' -E "s/^(    MARKETING_VERSION: ).*/\1\"$version\"/; s/^(    CURRENT_PROJECT_VERSION: ).*/\1\"$build\"/" project.yml

rm -rf "$out"
mkdir -p "$out"
xcodegen generate --quiet
# Built from the project, not install.sh's workspace, so the engine is the pinned GitHub release and not a local checkout.
xcodebuild archive -project Theseus.xcodeproj -scheme Theseus -configuration Release -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath "$derived" -allowProvisioningUpdates | grep -E " error:|^\*\* ARCHIVE" || true
[[ -d $archive ]] || fail "archive failed"

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$(sed -nE 's/^ +DEVELOPMENT_TEAM: (.*)/\1/p' project.yml)</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates | grep -E " error:|^\*\* EXPORT" || true
[[ -d $app ]] || fail "export failed"
codesign --verify --deep --strict "$app"

mkdir "$out/dmg"
ditto "$app" "$out/dmg/Theseus.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -quiet -volname Theseus -srcfolder "$out/dmg" -format UDZO "$dmg"
codesign --sign "Developer ID Application" --timestamp "$dmg"

echo "notarizing $dmg"
result=$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json)
verdict=$(plutil -extract status raw - <<< "$result")

if [[ $verdict != Accepted ]]; then
  xcrun notarytool log "$(plutil -extract id raw - <<< "$result")" --keychain-profile "$profile" >&2
  fail "notarization: $verdict"
fi

xcrun stapler staple -q "$dmg"
spctl --assess --type open --context context:primary-signature "$dmg"
spctl --assess --type execute "$app"

if (( ! publish )); then
  echo "built $dmg (not published)"
  exit 0
fi

git commit -q -m "Release $version" -- project.yml
git tag -a "v$version" -m "Theseus $version"
git push -q origin main "v$version"
gh release create "v$version" "$dmg" --title "Theseus $version" --notes-file "$notes" --verify-tag
