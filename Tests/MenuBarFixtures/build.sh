#!/bin/zsh
# Builds "Audit Alpha.app" (local.audit.alpha: A1, A2) and "Audit Beta.app" (local.audit.beta: B1)
# into a new temporary folder and prints its path. Never installs or launches them.
# Each bundle gets its own executable name; --shared-executable gives both "AuditFixture",
# reproducing the 2026-10-11 audit fixtures.
set -euo pipefail
cd "$(dirname "$0")"

shared=false
[[ "${1:-}" == --shared-executable ]] && shared=true
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application:/{print $2; exit}')
[[ -n "$SIGN_ID" ]] || { print -u2 "No Developer ID Application identity in the keychain."; exit 1 }

OUT=$(mktemp -d /tmp/menubar-fixtures.XXXXXX)
for name in Alpha Beta; do
    exe=$([[ $shared == true ]] && echo AuditFixture || echo "Audit$name")
    app="$OUT/Audit $name.app"
    mkdir -p "$app/Contents/MacOS"
    # Explicit target: swiftc defaults to the host OS, which older guests refuse to launch (LS error -10825).
    swiftc -O -target arm64-apple-macos15.0 Fixture.swift -o "$app/Contents/MacOS/$exe"
    plutil -create xml1 "$app/Contents/Info.plist"
    plutil -insert CFBundleExecutable -string "$exe" "$app/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "local.audit.${(L)name}" "$app/Contents/Info.plist"
    plutil -insert CFBundleName -string "Audit $name" "$app/Contents/Info.plist"
    plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
    plutil -insert LSUIElement -bool true "$app/Contents/Info.plist"
    plutil -insert LSMinimumSystemVersion -string 15.0 "$app/Contents/Info.plist"
    # No hardened runtime, like the audit fixtures, so runs differ only in executable name.
    codesign --force --sign "$SIGN_ID" "$app"
    codesign --verify --strict "$app"
done
echo "$OUT"
