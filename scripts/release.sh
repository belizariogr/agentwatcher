#!/bin/bash
# Build a universal AgentWatcher.app, sign it with a Developer ID, wrap it in a
# DMG, notarize and staple. Output: build/AgentWatcher-<version>.dmg
#
# Credentials (from the environment, or ./.env, which Git ignores):
#   MACOS_P12_FILE + MACOS_P12_PASSWORD   Developer ID .p12, imported into a
#                                         temporary keychain (CI). Without it,
#                                         the login keychain is used (local).
#   MACOS_CODESIGN_IDENTITY               optional SHA-1 or name; default: the
#                                         only "Developer ID Application".
#   MACOS_TEAM_ID                         default 3Z7C3Q7NMT
#   MACOS_NOTARY_APPLE_ID + MACOS_NOTARY_PASSWORD (app-specific password), or
#   MACOS_NOTARY_PROFILE                  a `notarytool store-credentials` profile.
#   SKIP_NOTARIZE=1                       sign only (quick local check).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

fail() { echo "release: $*" >&2; exit 1; }

TEAM_ID="${MACOS_TEAM_ID:-3Z7C3Q7NMT}"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "invalid MACOS_TEAM_ID"

# --- Temporary keychain for a .p12 (never touches the login keychain) -------
tmp_dir=""
keychain=""
original_keychains=()
cleanup() {
  if [[ -n "$keychain" ]]; then
    security list-keychains -d user -s ${original_keychains[@]+"${original_keychains[@]}"} >/dev/null 2>&1 || true
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi
  [[ -z "$tmp_dir" ]] || rm -rf "$tmp_dir"
}
trap cleanup EXIT
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentwatcher-release.XXXXXX")"

if [[ -n "${MACOS_P12_FILE:-}" ]]; then
  [[ -f "$MACOS_P12_FILE" ]] || fail "certificate not found: $MACOS_P12_FILE"
  [[ -n "${MACOS_P12_PASSWORD:-}" ]] || fail "MACOS_P12_PASSWORD is required with MACOS_P12_FILE"
  keychain="$tmp_dir/signing.keychain-db"
  while IFS= read -r item; do
    [[ -z "$item" ]] || original_keychains+=("$item")
  done < <(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
  keychain_password="$(openssl rand -base64 32)"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security list-keychains -d user -s "$keychain" ${original_keychains[@]+"${original_keychains[@]}"}
  security import "$MACOS_P12_FILE" -k "$keychain" -P "$MACOS_P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null || fail "could not open the .p12 (check MACOS_P12_PASSWORD)"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
  unset keychain_password
fi

# --- Signing identity ---------------------------------------------------------
identity="${MACOS_CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  matches="$(security find-identity -v -p codesigning ${keychain:+"$keychain"} \
    | grep "Developer ID Application: .*($TEAM_ID)" | awk '{print $2}' | sort -u)"
  [[ -n "$matches" ]] || fail "no \"Developer ID Application\" identity for team $TEAM_ID"
  [[ "$(wc -l <<<"$matches" | tr -d ' ')" == "1" ]] || fail "several Developer ID identities; set MACOS_CODESIGN_IDENTITY"
  identity="$matches"
fi
sign_args=(--force --options runtime --timestamp --sign "$identity")
[[ -z "$keychain" ]] || sign_args+=(--keychain "$keychain")

# --- Notary credentials (checked before the slow build) ----------------------
notary_args=()
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  if [[ -n "${MACOS_NOTARY_APPLE_ID:-}" && -n "${MACOS_NOTARY_PASSWORD:-}" ]]; then
    notary_args=(--apple-id "$MACOS_NOTARY_APPLE_ID" --password "$MACOS_NOTARY_PASSWORD" --team-id "$TEAM_ID")
  elif [[ -n "${MACOS_NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$MACOS_NOTARY_PROFILE")
  else
    fail "set MACOS_NOTARY_APPLE_ID + MACOS_NOTARY_PASSWORD, or MACOS_NOTARY_PROFILE (or SKIP_NOTARIZE=1)"
  fi
  xcrun notarytool history "${notary_args[@]}" --output-format json >/dev/null \
    || fail "notary credentials were rejected"
fi

# --- Build and sign the app ---------------------------------------------------
UNIVERSAL=1 ./scripts/build-app.sh
APP="build/AgentWatcher.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
archs="$(lipo -archs "$APP/Contents/MacOS/AgentWatcher")"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "binary is not universal ($archs)"

codesign "${sign_args[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
codesign --verify --strict -R "$requirement" "$APP" || fail "app is not signed with a Developer ID of $TEAM_ID"

# --- DMG ----------------------------------------------------------------------
DMG="build/AgentWatcher-$VERSION.dmg"
stage="$tmp_dir/dmg"
mkdir -p "$stage"
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Agent Watcher" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
codesign "${sign_args[@]}" --identifier com.belizariogr.agentwatcher.dmg "$DMG"

# --- Notarize and staple ------------------------------------------------------
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "release: signed, NOT notarized (SKIP_NOTARIZE=1): $DMG"
  exit 0
fi

result="$tmp_dir/notary.json"
xcrun notarytool submit "$DMG" "${notary_args[@]}" --wait --timeout 30m --output-format json >"$result" || true
status="$(plutil -extract status raw "$result" 2>/dev/null || echo unknown)"
if [[ "$status" != "Accepted" ]]; then
  id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
  [[ -z "$id" ]] || xcrun notarytool log "$id" "${notary_args[@]}" >&2 || true
  fail "notarization status: $status"
fi

for attempt in 1 2 3 4 5; do
  xcrun stapler staple "$DMG" && break
  [[ "$attempt" == 5 ]] && fail "stapler failed"
  sleep $((attempt * 10))
done
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Gatekeeper check of the app as a user would get it from the DMG.
mount="$tmp_dir/mount"
mkdir -p "$mount"
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$mount" "$DMG"
spctl --assess --type execute --verbose=2 "$mount/AgentWatcher.app" || { hdiutil detach "$mount" -quiet; fail "Gatekeeper rejected the app"; }
hdiutil detach "$mount" -quiet

shasum -a 256 "$DMG"
echo "release: $DMG"
