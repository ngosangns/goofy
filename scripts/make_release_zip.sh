#!/bin/bash
# Zip Goofy.app the way AppUpdater can install it.
#
# AppUpdater (s1ntoneli/AppUpdater 0.2.0) downloads Goofy-<version>.zip and
# extracts it with /usr/bin/unzip. The archive must contain a top-level
# Goofy.app. Use `zip -r -y`, not ditto: Xcode's com.apple.provenance xattr
# becomes AppleDouble `._*` entries under ditto, and unzip writes those into
# the bundle and breaks the code signature.
#
# Usage: scripts/make_release_zip.sh <path-to-Goofy.app> <version> <output.zip>

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <Goofy.app> <version> <output.zip>" >&2
  exit 2
fi

APP_INPUT=$1
VERSION=$2
OUT_INPUT=$3

if [ ! -d "$APP_INPUT" ]; then
  echo "app not found: $APP_INPUT" >&2
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must be MAJOR.MINOR.PATCH, got: $VERSION" >&2
  exit 1
fi

APP_DIR=$(cd "$(dirname "$APP_INPUT")" && pwd)
APP_NAME=$(basename "$APP_INPUT")
if [ "$APP_NAME" != "Goofy.app" ]; then
  echo "expected Goofy.app, got $APP_NAME" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_INPUT")"
OUT_DIR=$(cd "$(dirname "$OUT_INPUT")" && pwd)
OUT="${OUT_DIR}/$(basename "$OUT_INPUT")"
rm -f "$OUT"

# Apple's zip records resource forks unless this is set. That would put
# `._*` members in the archive. AppUpdater's unzip would materialize them.
export COPYFILE_DISABLE=1
(cd "$APP_DIR" && zip -r -y "$OUT" "$APP_NAME")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/unzip -q "$OUT" -d "$STAGE"

appledouble=$(find "$STAGE" -name '._*' -print -quit)
if [ -n "$appledouble" ]; then
  echo "zip contains AppleDouble ._ files; AppUpdater unzip would break the signature" >&2
  find "$STAGE" -name '._*' -print >&2
  exit 1
fi

if [ ! -d "$STAGE/Goofy.app" ]; then
  echo "zip is missing a top-level Goofy.app" >&2
  exit 1
fi

SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Goofy.app/Contents/Info.plist")
if [ "$SHORT" != "$VERSION" ]; then
  echo "CFBundleShortVersionString is ${SHORT}, expected ${VERSION}" >&2
  exit 1
fi

codesign --verify --deep --strict "$STAGE/Goofy.app"
echo "wrote ${OUT}"
