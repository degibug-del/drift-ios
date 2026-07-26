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

# The Key ID is NOT a secret — it is literally the .p8's filename — so prompting for it
# blind bought nothing and cost a silent failure: typed into a hidden field, one wrong
# character produced "no key at …" and looked like the script had simply died. Read it off
# the file instead, and only ask when the answer is genuinely ambiguous.
KEYDIR="$HOME/.appstoreconnect/private_keys"
mapfile -t KEYS < <(ls "$KEYDIR"/AuthKey_*.p8 2>/dev/null || true)

if [ "${#KEYS[@]}" -eq 0 ]; then
  echo "no API key found in $KEYDIR" >&2
  echo "App Store Connect → Users and Access → Integrations → App Store Connect API," >&2
  echo "generate a key with the App Manager role, then:" >&2
  echo "  mkdir -p $KEYDIR && mv ~/Downloads/AuthKey_*.p8 $KEYDIR/" >&2
  exit 1
elif [ "${#KEYS[@]}" -eq 1 ]; then
  KEYFILE="${KEYS[0]}"
else
  echo "more than one key in $KEYDIR — pick one:" >&2
  select k in "${KEYS[@]}"; do KEYFILE="$k"; break; done
  [ -n "${KEYFILE:-}" ] || exit 1
fi

KEY_ID=$(basename "$KEYFILE" .p8); KEY_ID="${KEY_ID#AuthKey_}"
echo "  key     : $KEY_ID  (from $(basename "$KEYFILE"))"

# The issuer id IS worth not echoing, and it is the only thing left to ask for. Trimmed,
# because a pasted UUID picks up whitespace and the failure that produces is opaque.
read -rsp "  Issuer ID (hidden, paste it): " ISSUER_ID; echo
ISSUER_ID="$(printf '%s' "$ISSUER_ID" | tr -d '[:space:]')"
[ -n "$ISSUER_ID" ] || { echo "an issuer id is required — it is on the same page as the key." >&2; exit 1; }

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

# Pin the toolchain to the RELEASE Xcode, never a beta.
#
# Build 2 was archived by release Xcode 26.6 against the iOS 26.5 SDK — which meets
# Apple's published requirement (Xcode 26+, iOS 26 SDK, effective 2026-04-28) — and was
# still rejected with ITMS-90111 "Unsupported SDK or Xcode version". The one part of that
# pipeline that was not release software was the UPLOADER: distribution went through
# Xcode 27 beta 4's Organizer, because the release Xcode's GUI would not launch
# (error -10664). Uploading through a beta stamps beta tooling onto the submission.
#
# So the toolchain is chosen here rather than inherited from whatever xcode-select
# happens to point at, and a beta is refused outright instead of being discovered in a
# rejection email a day later.
RELEASE_XCODE="${LASERBRAIN_XCODE:-/Applications/Xcode.app}"
if [ -d "$RELEASE_XCODE/Contents/Developer" ]; then
  export DEVELOPER_DIR="$RELEASE_XCODE/Contents/Developer"
fi
XV=$("$DEVELOPER_DIR/usr/bin/xcodebuild" -version 2>/dev/null | head -1)
case "$XV" in
  *beta*|*Beta*) echo "REFUSING: $XV is a beta. Apple rejects submissions built or uploaded with beta tooling." >&2; exit 1;;
esac
echo "  toolchain: ${XV:-unknown}"

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
