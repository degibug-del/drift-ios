#!/bin/bash
# upload-build.sh — send a built archive to App Store Connect.
#
# WHY THIS EXISTS. `xcodebuild -exportArchive -destination upload` cannot borrow the
# account you signed into Xcode's GUI: it authenticates, then fails resolving the
# provider id ("Unexpected nil property at path: 'Actor/relationships/providerId'").
# An API key carries an ISSUER ID, which is that provider identifier, so the same
# upload works. That is the whole reason for the key — not extra permissions.
#
# WHAT IT NEVER DOES. It does not take your key id or issuer id as arguments and it
# does not store them. Arguments land in shell history and in `ps` output; these are
# read here, held for the length of one upload, and discarded. The .p8 itself stays
# wherever Apple's tooling expects it and is never copied or printed.
#
# ONE-TIME SETUP
#   1. App Store Connect -> Users and Access -> Integrations -> App Store Connect API
#   2. Generate an API Key with the App Manager role
#   3. Download the .p8 — Apple lets you download it ONCE — and move it to:
#        mkdir -p ~/.appstoreconnect/private_keys
#        mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
#   4. Note the Key ID (10 chars) and the Issuer ID (a UUID) from that same page
#
# USAGE
#   ./upload-build.sh                        # uses the newest archive on the Desktop
#   ./upload-build.sh /path/to/My.xcarchive  # or name one
set -euo pipefail

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  ARCHIVE=$(ls -dt "$HOME/Desktop"/*.xcarchive 2>/dev/null | head -1 || true)
fi
[ -n "$ARCHIVE" ] && [ -d "$ARCHIVE" ] || {
  echo "no archive found. pass one: ./upload-build.sh /path/to/App.xcarchive" >&2; exit 1; }

APP=$(ls -d "$ARCHIVE"/Products/Applications/*.app 2>/dev/null | head -1 || true)
[ -n "$APP" ] || { echo "no .app inside $ARCHIVE" >&2; exit 1; }
PL="$APP/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PL" 2>/dev/null || echo "?"; }

# Show what is about to be sent BEFORE asking for anything. An upload is hard to take
# back — the build number is burned in App Store Connect even if you delete it — so the
# identity gets confirmed while it is still free to stop.
echo
echo "  archive : $ARCHIVE"
echo "  bundle  : $(pb CFBundleIdentifier)"
echo "  name    : $(pb CFBundleDisplayName)"
echo "  version : $(pb CFBundleShortVersionString) (build $(pb CFBundleVersion))"
echo "  sdk     : $(pb DTSDKName)   <- must NOT be a beta sdk; Apple rejects those"
echo

# A beta SDK is the one failure worth refusing outright rather than discovering after a
# 20-minute upload and a rejection email.
SDK=$(pb DTSDKName)
case "$SDK" in
  *beta*) echo "REFUSING: built against a beta SDK ($SDK). Re-archive with the release Xcode." >&2; exit 1;;
esac

read -r -p "upload this build? [y/N] " ok
[ "$ok" = "y" ] || [ "$ok" = "Y" ] || { echo "stopped."; exit 0; }

# -s keeps these off the screen and out of scrollback.
read -rsp "App Store Connect Key ID: " KEY_ID; echo
read -rsp "Issuer ID: " ISSUER_ID; echo

[ -n "$KEY_ID" ] && [ -n "$ISSUER_ID" ] || { echo "both are required." >&2; exit 1; }

KEYFILE="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
[ -f "$KEYFILE" ] || {
  echo "no key at $KEYFILE" >&2
  echo "move the downloaded .p8 there, named exactly AuthKey_<KEYID>.p8" >&2
  exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>4PJR6LBLBA</string>
	<key>uploadSymbols</key><true/>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo
echo "uploading — this takes a few minutes and says nothing while it works…"

# No pipe to tail here, deliberately. Piping makes the shell report the exit status of
# `tail` instead of xcodebuild, so a failed upload reads as success — which is exactly
# how the first attempt at this looked like it had worked when it had not.
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$TMP/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEYFILE" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  > "$TMP/upload.log" 2>&1
CODE=$?
set -e

if [ $CODE -eq 0 ]; then
  echo
  echo "  UPLOADED. It now processes on Apple's side — usually 5 to 15 minutes — and then"
  echo "  appears on the version page where it can be selected for the submission."
else
  echo
  echo "  UPLOAD FAILED (exit $CODE). The real reason:"
  echo
  grep -iE "error|failed" "$TMP/upload.log" | tail -12 | sed 's/^/    /'
  echo
  cp "$TMP/upload.log" "$HOME/Desktop/drift-upload-failure.log"
  echo "  full log: ~/Desktop/drift-upload-failure.log"
  exit $CODE
fi
