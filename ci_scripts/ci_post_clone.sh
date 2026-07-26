#!/bin/sh
# ci_post_clone.sh — Xcode Cloud runs this after checking the repo out.
#
# WHY IT EXISTS. Xcode Cloud numbers its builds with its own counter starting at 1 and
# uses that as the bundle version, ignoring CURRENT_PROJECT_VERSION in the project. Five
# builds had already been uploaded from this machine, so Xcode Cloud build 2 tried to
# deliver bundle version 2 and App Store Connect refused it:
#
#   Prepare Build for App Store Connect
#   The bundle version must be higher than the previously uploaded version.
#
# Nothing was wrong with the archive. The number simply collided with history.
#
# So the bundle version is derived from Xcode Cloud's counter plus an offset that clears
# every locally-made build. Monotonic by construction: CI_BUILD_NUMBER only increases, so
# this only increases, and it can never collide with the 1..5 already uploaded.
#
# Raise BASE, never lower it — App Store Connect remembers every version ever delivered,
# including ones that were rejected.
set -e

BASE=100
BUILD_NUMBER=$((BASE + ${CI_BUILD_NUMBER:-0}))

echo "ci_post_clone: setting bundle version to ${BUILD_NUMBER} (base ${BASE} + CI_BUILD_NUMBER ${CI_BUILD_NUMBER:-0})"

# The project generates its Info.plist from build settings (GENERATE_INFOPLIST_FILE), so
# CURRENT_PROJECT_VERSION in the pbxproj is the single place the version comes from —
# there is no checked-in plist that could disagree with it.
PROJ="$CI_PRIMARY_REPOSITORY_PATH/DRIFT.xcodeproj/project.pbxproj"
if [ ! -f "$PROJ" ]; then
  echo "ci_post_clone: cannot find $PROJ" >&2
  exit 1
fi

sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};/g" "$PROJ"

# Prove the edit landed rather than trusting sed's silence: a string replace that matches
# nothing exits 0 and prints nothing, which reads exactly like success.
COUNT=$(grep -c "CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};" "$PROJ" || true)
if [ "$COUNT" -lt 1 ]; then
  echo "ci_post_clone: version rewrite did not take — no config was updated" >&2
  exit 1
fi
echo "ci_post_clone: ${COUNT} build configuration(s) now at ${BUILD_NUMBER}"
