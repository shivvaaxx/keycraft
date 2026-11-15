#!/bin/zsh
# Builds a Developer ID–signed, notarized, stapled Keycraft.dmg in build/.
# Needs Xcode signed in to an account on team 32DYANNXSC (Xcode ▸ Settings ▸ Accounts).
# Notarization goes through that Xcode account, so no app-specific password is needed.
set -euo pipefail
cd "${0:A:h}/.."

TEAM=32DYANNXSC
ARCHIVE=build/Archive/Keycraft.xcarchive
rm -rf build/Archive build/Upload build/Notarized build/dmg-stage build/Keycraft.dmg

xcodegen generate
xcodebuild -project Keycraft.xcodeproj -scheme Keycraft -configuration Release -archivePath $ARCHIVE archive \
  DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates

cat > build/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>upload</string>
</dict></plist>
EOF
# Signs with Developer ID and submits to Apple's notary service.
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath build/Upload -exportOptionsPlist build/export.plist -allowProvisioningUpdates

echo "Waiting for notarization…"
until xcodebuild -exportNotarizedApp -archivePath $ARCHIVE -exportPath build/Notarized -allowProvisioningUpdates >/dev/null 2>&1; do
  sleep 30
done

APP=build/Notarized/Keycraft.app
spctl -a -vv -t exec $APP   # expect: source=Notarized Developer ID

mkdir -p build/dmg-stage
cp -R $APP build/dmg-stage/
ln -s /Applications build/dmg-stage/Applications
# The DMG itself stays unsigned: the app inside carries the stapled notarization ticket that Gatekeeper checks.
# (A signed-but-unnotarized DMG would be assessed on open; notarizing the DMG too needs notarytool credentials.)
hdiutil create -volname Keycraft -srcfolder build/dmg-stage -ov -format UDZO -fs HFS+ build/Keycraft.dmg
shasum -a 256 build/Keycraft.dmg
