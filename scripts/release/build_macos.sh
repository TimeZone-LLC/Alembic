#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${1:-$(grep '^version:' "$ROOT/pubspec.yaml" | sed -E 's/^version:[[:space:]]*//')}"
OUT="${2:-$ROOT/release}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
MACOS_SKIP_SIGNING="${MACOS_SKIP_SIGNING:-1}"
ALEMBIC_BUILD_ID="${ALEMBIC_BUILD_ID:-}"

if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  if [[ -x /Users/brianfopiano/Developer/flutter/bin/flutter ]]; then
    FLUTTER_BIN=/Users/brianfopiano/Developer/flutter/bin/flutter
  fi
fi

mkdir -p "$OUT"
rm -f "$OUT/Alembic-$VERSION-macos-universal.zip" "$OUT/Alembic-$VERSION-macos.dmg"

cd "$ROOT"
"$FLUTTER_BIN" pub get
rm -rf "$ROOT/build/macos" "$ROOT/build/native_assets/macos"
FLUTTER_BUILD_ARGS=(build macos --release --config-only --no-pub)
if [[ -n "$ALEMBIC_BUILD_ID" ]]; then
  FLUTTER_BUILD_ARGS+=(--dart-define="ALEMBIC_BUILD_ID=$ALEMBIC_BUILD_ID")
fi
"$FLUTTER_BIN" "${FLUTTER_BUILD_ARGS[@]}"
if ! xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -derivedDataPath build/macos \
  -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build; then
  echo "Native assets after failed macOS build:" >&2
  find "$ROOT/build/native_assets" -maxdepth 4 -print 2>/dev/null >&2 || true
  echo "Bundled native asset manifests after failed macOS build:" >&2
  find "$ROOT/build/macos" -name NativeAssetsManifest.json -print 2>/dev/null >&2 || true
  exit 1
fi

APP_SOURCE="$ROOT/build/macos/Build/Products/Release/Alembic.app"
if [[ ! -d "$APP_SOURCE" ]]; then
  APP_SOURCE="$ROOT/build/macos/Build/Products/Release/alembic.app"
fi
if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Could not find built Alembic.app" >&2
  exit 1
fi

STAGE="$ROOT/build/release/macos"
DMG_STAGE="$ROOT/build/release/dmg"
APP_STAGE="$STAGE/Alembic.app"
rm -rf "$STAGE" "$DMG_STAGE"
mkdir -p "$STAGE" "$DMG_STAGE"
cp -R "$APP_SOURCE" "$APP_STAGE"

if [[ "${MACOS_SKIP_SIGNING:-}" != "1" ]]; then
  if [[ -z "${MACOS_CODESIGN_IDENTITY:-}" ]]; then
    echo "MACOS_CODESIGN_IDENTITY is required unless MACOS_SKIP_SIGNING=1" >&2
    exit 1
  fi
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ]]; then
    echo "APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID are required unless MACOS_SKIP_SIGNING=1" >&2
    exit 1
  fi
  codesign --deep --force --options runtime --timestamp --sign "$MACOS_CODESIGN_IDENTITY" "$APP_STAGE"
  codesign --verify --deep --strict "$APP_STAGE"
  NOTARY_ZIP="$ROOT/build/release/Alembic-notary.zip"
  rm -f "$NOTARY_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP_STAGE" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
  xcrun stapler staple "$APP_STAGE"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_STAGE" "$OUT/Alembic-$VERSION-macos-universal.zip"
cp -R "$APP_STAGE" "$DMG_STAGE/Alembic.app"
ln -s /Applications "$DMG_STAGE/Applications"
DMG_LOG="$ROOT/build/release/dmg-create.log"
for attempt in 1 2 3; do
  if hdiutil create -volname Alembic -srcfolder "$DMG_STAGE" -fs HFS+ -ov -format UDZO "$OUT/Alembic-$VERSION-macos.dmg" >"$DMG_LOG" 2>&1; then
    cat "$DMG_LOG"
    break
  fi
  cat "$DMG_LOG" >&2
  if [[ "$attempt" == "3" ]] || ! grep -q 'Resource busy' "$DMG_LOG"; then
    exit 1
  fi
  sleep "$attempt"
done

if [[ "${MACOS_SKIP_SIGNING:-}" != "1" ]]; then
  xcrun notarytool submit "$OUT/Alembic-$VERSION-macos.dmg" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
  xcrun stapler staple "$OUT/Alembic-$VERSION-macos.dmg"
fi
