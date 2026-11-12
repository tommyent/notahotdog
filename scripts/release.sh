#!/bin/zsh
# Official build: Developer ID signature with the hardened runtime and no entitlements, then a notarized,
# stapled app inside a notarized, stapled DMG, its checksum, Sparkle's appcast and a manifest in
# build.noindex/release.XXXXXX. Fails closed: it exits non-zero unless Apple accepts both submissions, both
# staples validate and Gatekeeper accepts the app and the DMG.
# Needs a "Developer ID Application" identity (DEVELOPER_ID picks one when there are several), a notarytool
# keychain profile (NOTARY_PROFILE, default "notary"), Sparkle's EdDSA key in the login Keychain (account
# "notahotdog") and the release notes in docs/notes/NotAHotDog-<version>.md.
# Nothing is uploaded. To publish: attach the DMG and its .sha256 to the GitHub release v<version>, then
# commit the docs/appcast.xml this script leaves behind (GitHub Pages serves docs/).
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-notary}"
KEY_ACCOUNT=notahotdog
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
NAME="Not A Hot Dog"
FILE=NotAHotDog
SITE=https://tommyent.github.io/notahotdog
fail() { print -u2 -- "release: $1"; exit 1 }

git diff --quiet HEAD -- || fail "commit the tracked changes first: a release is built from a commit"
# Untracked files count too: SwiftPM compiles everything in Sources.
[[ -z "$(git status --porcelain -- Sources Assets Info.plist Package.swift Package.resolved build.sh scripts)" ]] \
    || fail "commit or remove the untracked build files first: a release is built from a commit"
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    IDS=("${(@f)$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)"$/\1/p' | sort -u)}")
    (( ${#IDS} == 1 )) && [[ -n "${IDS[1]}" ]] || fail "set DEVELOPER_ID: expected one Developer ID Application identity"
    DEVELOPER_ID="${IDS[1]}"
fi
TEAM="${${DEVELOPER_ID##*\(}%\)}"

./build.sh --only-use-versions-from-resolved-file
PLIST="build.noindex/$NAME.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NOTES="docs/notes/$FILE-$VERSION.md"
[[ -s "$NOTES" ]] || fail "write the release notes first: $NOTES"
git ls-files --error-unmatch -- "$NOTES" > /dev/null 2>&1 || fail "commit the release notes first: $NOTES is untracked"
# Sparkle offers an update only when its build number is higher than the installed one.
if [[ -s docs/appcast.xml ]]; then
    NEWEST="$(sed -n 's/.*<sparkle:version>\([0-9]*\)<\/sparkle:version>.*/\1/p' docs/appcast.xml | sort -n | tail -1)"
    # shortcut: the same version again passes, for rebuilding a release that was never published;
    # drop this exception if a published release ever has to be rebuilt.
    grep -qF "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" docs/appcast.xml || (( BUILD > ${NEWEST:-0} )) \
        || fail "CFBundleVersion $BUILD must be greater than $NEWEST, the newest build in docs/appcast.xml"
fi
# An update signed with any other key would be refused by every installed copy
[[ "$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p)" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" ]] \
    || fail "SUPublicEDKey in Info.plist is not the public half of the Keychain's $KEY_ACCOUNT key"
OUT="$(mktemp -d build.noindex/release.XXXXXX)"
APP="$OUT/$NAME.app"
ditto "build.noindex/$NAME.app" "$APP"

# Signed again with a secure timestamp, which notarization needs: nested code first, inside-out and
# without --deep, as Sparkle's documentation signs it; then the app. No entitlements: the app needs none.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW" "$APP"; do
    codesign -f -s "$DEVELOPER_ID" --options runtime --timestamp "$code"
done
codesign --verify --deep --strict --verbose=2 "$APP"
for f in "$APP" "$APP"/Contents/**/*(.ND); do   # every piece of code, so nothing unsigned by us slips in
    [[ "$f" == "$APP" || "$(file -b "$f")" == Mach-O* ]] || continue
    INFO="$(codesign -dv "$f" 2>&1)"
    [[ "$INFO" == *"flags=0x10000(runtime)"* && "$INFO" == *"TeamIdentifier=$TEAM"* && "$INFO" == *Timestamp=* ]] \
        || fail "$f: signature lacks the hardened runtime, Team ID $TEAM or a secure timestamp"
done
for f in "$APP"/Contents/**/*(.ND); do   # symbol tables too: strings and grep don't see them
    [[ "$(file -b "$f")" == Mach-O* ]] || continue
    ! nm -a "$f" 2>/dev/null | grep -q /Users/ || fail "$f: its symbols name a home folder path; strip them in build.sh"
done
[[ -z "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" ]] || fail "the app must be signed without entitlements"

NOTARY=()
notarize() {   # $1: the file to submit; returns only when Apple's answer is Accepted
    local name="${1:t}" id notary_status
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/$name.notary.json" || true
    id="$(plutil -extract id raw "$OUT/$name.notary.json")"
    notary_status="$(plutil -extract status raw "$OUT/$name.notary.json")"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/$name.notary-log.json" || true
    print -r -- "notarization of $name: $notary_status ($id)"
    [[ "$notary_status" == Accepted ]] || fail "notarization of $name: $notary_status, see $OUT/$name.notary-log.json"
    NOTARY+=("$name $id")
}
gatekeeper() {   # $@: spctl arguments; Gatekeeper must accept the item as notarized Developer ID
    local verdict
    verdict="$(spctl --assess -vvv "$@" 2>&1)" || fail "Gatekeeper rejected: $verdict"
    print -r -- "$verdict"
    [[ "$verdict" == *"source=Notarized Developer ID"* ]] || fail "not accepted as notarized: $verdict"
}

ditto -c -k --keepParent "$APP" "$OUT/$FILE.zip"
notarize "$OUT/$FILE.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
gatekeeper --type execute "$APP"

FINAL_DMG="$OUT/$FILE-$VERSION.dmg"
DMG="$OUT/unverified.dmg"   # gets its real name only once Apple and Gatekeeper have accepted it
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/$NAME.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$OUT/dmg" -format UDZO -o "$DMG"
codesign -s "$DEVELOPER_ID" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
gatekeeper --type open --context context:primary-signature "$DMG"
mv "$DMG" "$FINAL_DMG"
DMG="$FINAL_DMG"

(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")

# Sparkle's feed, one item: the stapled DMG's EdDSA signature, the download on GitHub Releases, notes on the site
mkdir "$OUT/updates"
cp "$DMG" "$OUT/updates/"
cp "$NOTES" "$OUT/updates/"
"$SPARKLE_BIN/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/tommyent/notahotdog/releases/download/v$VERSION/" \
    --release-notes-url-prefix "$SITE/notes/" \
    --link "$SITE/" "$OUT/updates"
APPCAST="$(<"$OUT/updates/appcast.xml")"
for want in "<sparkle:version>$BUILD</sparkle:version>" "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" \
    "url=\"https://github.com/tommyent/notahotdog/releases/download/v$VERSION/$FILE-$VERSION.dmg\"" \
    "length=\"$(stat -f %z "$DMG")\"" "sparkle:edSignature=" \
    "<sparkle:releaseNotesLink>$SITE/notes/$FILE-$VERSION.md</sparkle:releaseNotesLink>"; do
    [[ "$APPCAST" == *"$want"* ]] || fail "appcast lacks $want"
done
cp "$OUT/updates/appcast.xml" docs/appcast.xml   # left uncommitted: committing and pushing it publishes the update

cat > "$OUT/manifest.txt" <<EOF
version: $VERSION ($BUILD)
commit: $(git rev-parse HEAD)
sha256: $(cut -d' ' -f1 "$DMG.sha256")  ${DMG:t}
identity: $DEVELOPER_ID
team: $TEAM
notary: ${(j:, :)NOTARY}
appcast: $OUT/updates/appcast.xml, copied to docs/appcast.xml (EdDSA key: $KEY_ACCOUNT)
built on: macOS $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')SDK $(xcrun --sdk macosx --show-sdk-version), $(uname -m)
EOF
cat "$OUT/manifest.txt"
print "release: $OUT"
