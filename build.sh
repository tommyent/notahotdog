#!/bin/zsh
# Builds "Not A Hot Dog.app" into build.noindex, signed with a Developer ID and the hardened runtime.
# scripts/release.sh turns that into the notarized DMG and the appcast.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release "$@"
BIN="$(swift build -c release "$@" --show-bin-path)"

APP="build.noindex/Not A Hot Dog.app"  # .noindex: Spotlight/Raycast only see the /Applications copy
[[ ! -e "$APP" ]] || trash "$APP"      # a stale bundle could keep files this build no longer makes
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/NotAHotDog" "$APP/Contents/MacOS/"
strip -S "$APP/Contents/MacOS/NotAHotDog"  # the debug symbols name the build folder's full path
cp Info.plist "$APP/Contents/"
# Assets.car carries the Icon Composer icon macOS draws (light, dark, tinted).
xcrun actool Assets/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)" \
    --output-partial-info-plist /dev/null > /dev/null
cp Assets/AppIcon.icns "$APP/Contents/Resources/"  # the hand-drawn small sizes, over actool's fallback
# Sparkle with its symlinks and permissions; its XPC services are for sandboxed apps, so they stay out.
rsync -a --exclude XPCServices "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"

# Developer ID only: TCC grants follow the team ID across rebuilds. Ad-hoc or
# another identity makes macOS re-prompt for Screen Recording and Accessibility.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application:/{print $2; exit}')
[[ -n "$SIGN_ID" ]] || { print -u2 "No Developer ID Application identity in the keychain."; exit 1 }
# Hardened runtime: injected code (DYLD_INSERT_LIBRARIES) can't inherit our Accessibility/Screen Recording grants.
# Nested code first, inside-out and without --deep, as Sparkle's documentation signs it; then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW" "$APP"; do
    codesign --force --options runtime --sign "$SIGN_ID" "$code"
done
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/NotAHotDog" --check  # the signed binary, under hardened runtime
echo "Built: $APP"
