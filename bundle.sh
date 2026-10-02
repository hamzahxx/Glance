#!/bin/bash
# Builds Glance.app and GlanceProbe.app.
#
# A bundle is what makes camera TCC work: macOS keys the permission grant to a
# bundle identifier and code signature, so the ad-hoc signature is reapplied on
# every build to keep one identity across rebuilds.
set -euo pipefail

# ./bundle.sh [debug|release] [probe] [universal] [zip] [install] [dmg] [notarize]
#
# The probe is not built by default. It is a developer diagnostic, and a second
# app bundle named Glance* only clutters ⌘-Space for everyone who is not
# currently measuring head-pose separability.
CONFIG="debug"
WITH_PROBE="no"
ARCH_FLAGS=""
MAKE_ZIP="no"
INSTALL="no"
MAKE_DMG="no"
NOTARIZE="no"
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        probe) WITH_PROBE="yes" ;;
        # Intel Macs need their own slice; the host-only default will not run there.
        universal) ARCH_FLAGS="--arch arm64 --arch x86_64" ;;
        zip) MAKE_ZIP="yes" ;;
        install) INSTALL="yes" ;;
        # A disk image is what people expect to download; it implies a release
        # build for both architectures.
        dmg) MAKE_DMG="yes"; CONFIG="release"; ARCH_FLAGS="--arch arm64 --arch x86_64" ;;
        notarize) NOTARIZE="yes" ;;
    esac
done
# Accept the older label too, so an existing certificate keeps working after
# the rename rather than forcing every permission to be granted again.
SIGN_IDENTITY="Glance Local Signing"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "GazeGrid Local Signing"; then
        SIGN_IDENTITY="GazeGrid Local Signing"
    fi
fi
cd "$(dirname "$0")"

BIN_DIR="$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)"
swift build -c "$CONFIG" $ARCH_FLAGS >/dev/null

# make_bundle <product> <app-name> <bundle-id> <agent: true|false> <dir>
make_bundle() {
    local product="$1" name="$2" ident="$3" agent="$4" dir="${5:-build}"
    local app="$dir/$name.app"
    mkdir -p "$dir"

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN_DIR/$product" "$app/Contents/MacOS/$name"
    # Regenerate with: swift tools/make-icon.swift <dir> && iconutil -c icns <dir> -o Resources/Glance.icns
    [ -f Resources/Glance.icns ] && cp Resources/Glance.icns "$app/Contents/Resources/$name.icns"

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$name</string>
    <key>CFBundleDisplayName</key>     <string>$name</string>
    <key>CFBundleIdentifier</key>      <string>$ident</string>
    <key>CFBundleExecutable</key>      <string>$name</string>
    <key>CFBundleIconFile</key>        <string>$name</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <$agent/>
    <key>NSCameraUsageDescription</key>
    <string>Glance estimates head orientation locally to position the cursor. Frames are processed on-device and never stored or transmitted.</string>
</dict>
</plist>
PLIST

    # A stable identity keeps camera and Accessibility grants across rebuilds;
    # ad-hoc signatures change with the binary, so every build looks new to TCC.
    # Run ./setup-signing.sh once to create it.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
        codesign --force --sign "$SIGN_IDENTITY" "$app"
    else
        codesign --force --sign - "$app"
    fi
    echo "built $app"
}

# The app is a menu-bar agent; the probe needs real windows and focus.
make_bundle GlanceApp   Glance      com.glance.app   true

if [ "$INSTALL" = "yes" ]; then
    # A login item records the bundle's path, so a copy that lives somewhere
    # permanent is the one worth registering.
    mkdir -p "$HOME/Applications"
    ditto build/Glance.app "$HOME/Applications/Glance.app"
    echo "installed $HOME/Applications/Glance.app"
fi

if [ "$MAKE_DMG" = "yes" ]; then
    STAGE="build/dmg"
    rm -rf "$STAGE" build/Glance.dmg build/Glance.rw.dmg
    mkdir -p "$STAGE"
    ditto build/Glance.app "$STAGE/Glance.app"
    # The conventional install gesture: drag the app onto the alias.
    ln -s /Applications "$STAGE/Applications"

    # Read-write first, so Finder can be told how to present the window; the
    # layout it writes is only preserved if the image is writable at the time.
    hdiutil create -volname Glance -srcfolder "$STAGE" -ov -format UDRW \
        -size 64m -quiet build/Glance.rw.dmg
    rm -rf "$STAGE"

    MOUNT="$(hdiutil attach build/Glance.rw.dmg -nobrowse -noverify -noautoopen |
             grep -o '/Volumes/.*' | head -1)"

    if [ -n "$MOUNT" ]; then
        [ -f Resources/dmg-background.tiff ] && {
            mkdir -p "$MOUNT/.background"
            cp Resources/dmg-background.tiff "$MOUNT/.background/background.tiff"
        }
        # Finder scripting needs Automation permission. If it is refused the
        # image is still perfectly usable, just unstyled, so never fail here.
        osascript <<APPLESCRIPT 2>/dev/null || echo "  (Finder layout skipped — grant Automation to style the window)"
tell application "Finder"
    tell disk "Glance"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 110
        set text size of options to 12
        try
            set background picture of options to file ".background:background.tiff"
        end try
        set position of item "Glance.app" of container window to {170, 190}
        set position of item "Applications" of container window to {490, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

        # After Finder, not before: updating the window discards a volume icon
        # written beforehand.
        if [ -f Resources/Glance.icns ]; then
            cp Resources/Glance.icns "$MOUNT/.VolumeIcon.icns"
            SetFile -a C "$MOUNT" 2>/dev/null || true
        fi

        sync
        hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
    fi

    hdiutil convert build/Glance.rw.dmg -format UDZO -imagekey zlib-level=9 \
        -o build/Glance.dmg -ov -quiet
    rm -f build/Glance.rw.dmg

    # Signing the image says who produced it; it is not a substitute for
    # notarization, which is what actually silences Gatekeeper.
    codesign --force --sign "$SIGN_IDENTITY" build/Glance.dmg 2>/dev/null || true
    echo "packaged build/Glance.dmg  ($(lipo -archs build/Glance.app/Contents/MacOS/Glance))"

    if [ "$NOTARIZE" = "yes" ]; then
        # Requires a paid Apple Developer account and a stored credential:
        #   xcrun notarytool store-credentials glance-notary \
        #     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
        # The app must also be signed with a Developer ID Application certificate,
        # not the local self-signed one — notarization rejects anything else.
        echo "submitting for notarization (this takes a few minutes)…"
        xcrun notarytool submit build/Glance.dmg --keychain-profile glance-notary --wait
        xcrun stapler staple build/Glance.dmg
        echo "stapled — this image opens without any Gatekeeper warning"
    else
        echo "not notarized: first launch needs System Settings › Privacy & Security › Open Anyway"
    fi
fi

if [ "$MAKE_ZIP" = "yes" ]; then
    # ditto preserves the code signature; `zip` does not reliably.
    rm -f build/Glance.zip
    ditto -c -k --sequesterRsrc --keepParent build/Glance.app build/Glance.zip
    echo "packaged build/Glance.zip  ($(lipo -archs build/Glance.app/Contents/MacOS/Glance))"
    echo "send SHARING.md with it — the app is not notarized, so it needs one extra step on first open"
fi

rm -rf build/GlanceProbe.app
if [ "$WITH_PROBE" = "yes" ]; then
    mkdir -p build/tools
    touch build/tools/.metadata_never_index
    make_bundle GlanceProbe GlanceProbe com.glance.probe false build/tools
else
    rm -rf build/tools
fi
