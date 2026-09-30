#!/usr/bin/env bash
# Verify Frosty's Sparkle feed end to end, the way an installed copy would trust it.
#
#   scripts/verify-update-feed.sh                      # the production feed (SUFeedURL in Frosty/App/Info.plist)
#   scripts/verify-update-feed.sh https://host/appcast.xml
#   scripts/verify-update-feed.sh dist/0.1.0           # a local dist folder (or a path to its appcast.xml)
#
# For every <item> in the appcast it checks, and fails on the first mismatch:
#   - the feed URL and every enclosure URL are https, and the enclosure is the
#     github.com/cxrobx/frosty release asset Frosty-<version>-macOS.zip for its own version
#   - the enclosure is downloaded (remote) or found next to the appcast (local), and its
#     size equals the appcast's length
#   - the EdDSA signature verifies against SUPublicEDKey from the repo's
#     Frosty/App/Info.plist (public key only; this script cannot sign anything)
#   - inside the zip: CFBundleVersion / CFBundleShortVersionString / LSMinimumSystemVersion
#     equal the appcast's, and the app carries the same SUPublicEDKey and SUFeedURL, so it
#     can verify the updates that follow it
#   - the app's code signature is valid (deep, strict), stapled, and Gatekeeper calls it
#     Notarized Developer ID
#
# Needs curl, xmllint, ditto, codesign, spctl and swift (for scripts/ed25519-verify.swift).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_SRC="$ROOT/Frosty/App/Info.plist"
PLISTBUDDY=/usr/libexec/PlistBuddy

info() { printf '\033[1;33m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
die()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

plist_get() { "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null || true; }

for tool in curl xmllint ditto codesign spctl swift shasum; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

PUBKEY="$(plist_get "$PLIST_SRC" SUPublicEDKey)"
[[ -n "$PUBKEY" ]] || die "SUPublicEDKey is empty in $PLIST_SRC"
PLIST_FEED="$(plist_get "$PLIST_SRC" SUFeedURL)"
[[ "$PLIST_FEED" == https://* ]] || die "SUFeedURL in $PLIST_SRC is not https: '$PLIST_FEED'"

FEED="${1:-$PLIST_FEED}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/frosty-feed.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fetch() { # fetch URL OUTFILE: https only, including after redirects
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 2 --max-time 600 -o "$2" "$1"
}

# -- Locate the appcast ------------------------------------------------------------
case "$FEED" in
    http://*)  die "the feed must be https, got $FEED" ;;
    https://*) MODE=remote; XML="$TMP/appcast.xml"
               info "Fetching $FEED"
               fetch "$FEED" "$XML" || die "cannot download the feed: $FEED" ;;
    *://*)     die "unsupported feed scheme: $FEED" ;;
    *)         MODE=local
               if [[ -d "$FEED" ]]; then DIR="$FEED"; XML="$FEED/appcast.xml"
               else DIR="$(dirname "$FEED")"; XML="$FEED"; fi
               [[ -f "$XML" ]] || die "no appcast at $XML"
               DIR="$(cd "$DIR" && pwd)"
               info "Reading $XML (local; enclosures are expected next to it)" ;;
esac
xmllint --noout "$XML" || die "the appcast is not well-formed XML"

xp() { xmllint --xpath "string($1)" "$XML" 2>/dev/null || true; }
COUNT="$(xmllint --xpath 'count(//item)' "$XML")"
[[ "$COUNT" -ge 1 ]] || die "the appcast has no <item>"

# -- Each item ----------------------------------------------------------------------
for i in $(seq 1 "$COUNT"); do
    item="//item[$i]"
    url="$(xp "$item/enclosure/@url")"
    length="$(xp "$item/enclosure/@length")"
    sig="$(xp "$item/enclosure/@*[local-name()='edSignature']")"
    version="$(xp "$item/*[local-name()='version']")";                   [[ -n "$version" ]] || version="$(xp "$item/enclosure/@*[local-name()='version']")"
    short="$(xp "$item/*[local-name()='shortVersionString']")";          [[ -n "$short" ]]   || short="$(xp "$item/enclosure/@*[local-name()='shortVersionString']")"
    minos="$(xp "$item/*[local-name()='minimumSystemVersion']")"
    label="item $i (Frosty ${short:-?})"

    [[ -n "$url" && -n "$length" && -n "$sig" && -n "$version" && -n "$short" ]] \
        || die "$label: needs enclosure url, length, sparkle:edSignature, sparkle:version and sparkle:shortVersionString"
    [[ "$url" == https://* ]] || die "$label: enclosure URL is not https: $url"
    re='^https://github\.com/cxrobx/frosty/releases/download/v([0-9]+\.[0-9]+\.[0-9]+)/(Frosty-([0-9]+\.[0-9]+\.[0-9]+)-macOS\.zip)$'
    [[ "$url" =~ $re ]] || die "$label: enclosure is not a cxrobx/frosty release asset named Frosty-X.Y.Z-macOS.zip: $url"
    [[ "${BASH_REMATCH[1]}" == "$short" && "${BASH_REMATCH[3]}" == "$short" ]] \
        || die "$label: enclosure URL names version ${BASH_REMATCH[1]}/${BASH_REMATCH[3]} but the item says $short"
    name="${BASH_REMATCH[2]}"

    if [[ "$MODE" == remote ]]; then
        zip="$TMP/$name"
        info "$label: downloading $url"
        fetch "$url" "$zip" || die "$label: cannot download $url"
    else
        zip="$DIR/$name"
        [[ -f "$zip" ]] || die "$label: $name is not next to the appcast in $DIR"
    fi

    actual="$(stat -f%z "$zip")"
    [[ "$actual" == "$length" ]] || die "$label: appcast length is $length but $name is $actual bytes"
    ok "$label: $name is $actual bytes, as the appcast says"

    # The sidecar checksum, when present, is one more independent check.
    if [[ "$MODE" == local && -f "$zip.sha256" ]]; then
        (cd "$DIR" && shasum -a 256 -c "$name.sha256" >/dev/null 2>&1) || die "$label: $name.sha256 does not match"
        ok "$label: $name.sha256 matches"
    fi

    swift "$ROOT/scripts/ed25519-verify.swift" "$PUBKEY" "$sig" "$zip" >/dev/null 2>"$TMP/ed.err" \
        || die "$label: EdDSA signature does not verify against SUPublicEDKey in Frosty/App/Info.plist ($(cat "$TMP/ed.err"))"
    ok "$label: EdDSA signature verifies against SUPublicEDKey"

    out="$TMP/x$i"; mkdir -p "$out"
    ditto -x -k "$zip" "$out" || die "$label: cannot unzip $name"
    app="$out/Frosty.app"
    [[ -d "$app" ]] || die "$label: $name does not contain Frosty.app at its top level"
    plist="$app/Contents/Info.plist"
    [[ "$(plist_get "$plist" CFBundleVersion)" == "$version" ]] \
        || die "$label: app CFBundleVersion is '$(plist_get "$plist" CFBundleVersion)', appcast sparkle:version is '$version'"
    [[ "$(plist_get "$plist" CFBundleShortVersionString)" == "$short" ]] \
        || die "$label: app version is '$(plist_get "$plist" CFBundleShortVersionString)', appcast says '$short'"
    [[ -z "$minos" || "$(plist_get "$plist" LSMinimumSystemVersion)" == "$minos" ]] \
        || die "$label: app LSMinimumSystemVersion is '$(plist_get "$plist" LSMinimumSystemVersion)', appcast says '$minos'"
    [[ "$(plist_get "$plist" SUPublicEDKey)" == "$PUBKEY" ]] \
        || die "$label: the app's SUPublicEDKey differs from Frosty/App/Info.plist; it could not verify later updates"
    [[ "$(plist_get "$plist" SUFeedURL)" == "$PLIST_FEED" ]] \
        || die "$label: the app's SUFeedURL is '$(plist_get "$plist" SUFeedURL)', not $PLIST_FEED"
    ok "$label: Info.plist matches the appcast (version $short, build $version) and carries the same key and feed"

    codesign --verify --deep --strict "$app" 2>"$TMP/cs.err" \
        || die "$label: codesign --verify --deep --strict failed: $(cat "$TMP/cs.err")"
    xcrun stapler validate "$app" >/dev/null 2>&1 || die "$label: no stapled notarization ticket on Frosty.app"
    assess="$(spctl -a -t exec -vv "$app" 2>&1 || true)"
    grep -q 'source=Notarized Developer ID' <<<"$assess" || die "$label: Gatekeeper: $assess"
    ok "$label: code signature valid, stapled, Gatekeeper: Notarized Developer ID"
done

ok "feed verified: $COUNT item(s) ($FEED)"
