#!/usr/bin/env bash
# Build a signed, notarized Frosty release and stage everything for GitHub.
#
#   scripts/release.sh VERSION            # build + verify into dist/VERSION/, print the gh command
#   scripts/release.sh VERSION --publish  # the same, then run that gh command
#
# Nothing is committed, tagged, pushed or uploaded without --publish. Without it the
# only thing that leaves this Mac is the notarization upload to Apple.
#
# Before running:
#   1. Bump MARKETING_VERSION *and* CURRENT_PROJECT_VERSION in project.yml and commit.
#      MARKETING_VERSION is the version people read (0.1.1). CURRENT_PROJECT_VERSION is
#      an integer Sparkle compares to decide whether an update is newer; it must be
#      higher than the one in every earlier release tag, or installed copies will never
#      be offered the update. This script refuses a VERSION that does not match
#      MARKETING_VERSION, and a build number that has not gone up.
#   2. Have a clean git tree (dist/ and build/ are ignored) and no existing vVERSION tag
#      or release.
#
# What it does: archive -> Developer ID export -> notarize + staple the app -> zip
# (the Sparkle update archive) -> DMG (signed, notarized, stapled) -> EdDSA-sign the zip
# -> appcast.xml -> scripts/verify-update-feed.sh over the result.
#
# Environment (all optional):
#   NOTARY_PROFILE      notarytool keychain profile      (default: DiskSight, same team)
#   SIGN_IDENTITY       Developer ID Application identity (default below)
#   TEAM_ID             Apple team                       (default CCYV5HQZCM)
#   SPARKLE_BIN         dir with Sparkle's sign_update (default ~/.local/share/sparkle/2.10.0/bin,
#                       then the copy inside the resolved Sparkle package)
#   SPARKLE_ACCOUNT     Keychain account of the EdDSA key (default: frosty)
#   SPARKLE_ED_PRIVATE_FROSTY
#                       the EdDSA private key itself. When set, it is used instead of the
#                       Keychain, whose item macOS guards with a login-password prompt.
#                       Set it without ever typing or printing it, from the secret store:
#                         secret run -k SPARKLE_ED_PRIVATE_FROSTY -- scripts/release.sh 0.1.1
#
# The Release configuration in project.yml stays ad-hoc signed on purpose, so anyone can
# build from source without our certificate. This script asks xcodebuild for the
# Developer ID identity on the command line instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="cxrobx/frosty"
NOTARY_PROFILE="${NOTARY_PROFILE:-DiskSight}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Christopher Robinson (CCYV5HQZCM)}"
TEAM_ID="${TEAM_ID:-CCYV5HQZCM}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-frosty}"
PLIST_SRC="$ROOT/Frosty/App/Info.plist"
WORK="$ROOT/build/release"

info() { printf '\033[1;33m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# -- Arguments -----------------------------------------------------------------
VERSION=""
PUBLISH=false
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=true ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $arg (usage: scripts/release.sh VERSION [--publish])" ;;
        *)  [[ -z "$VERSION" ]] || die "only one VERSION, got '$VERSION' and '$arg'"; VERSION="$arg" ;;
    esac
done
[[ -n "$VERSION" ]] || die "usage: scripts/release.sh VERSION [--publish]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must look like 1.2.3, got '$VERSION'"
TAG="v$VERSION"

PLISTBUDDY=/usr/libexec/PlistBuddy
plist_get() { "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null; }

# Read a build setting's literal value out of project.yml text on stdin.
yml_value() { awk -v k="$1:" '$1 == k { v = $2; gsub(/"/, "", v); print v; exit }'; }

# -- Preflight: everything that can be checked before a 10-minute build ----------
info "Preflight for Frosty $VERSION"

for tool in xcodegen xcodebuild xcrun hdiutil ditto codesign spctl git shasum plutil xmllint curl swift; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

# 1. A clean tree and an unused tag. The release must be exactly what is committed.
[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
    || { git status --short >&2; die "git tree is dirty; commit or stash first (the release must be built from a commit)"; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"
REMOTE_TAGS="$(git ls-remote --tags --refs origin 'v[0-9]*' 2>/dev/null)" \
    || die "cannot reach origin to check for an existing $TAG"
REMOTE_TAGS="$(printf '%s\n' "$REMOTE_TAGS" | sed -n 's#.*refs/tags/##p')"
grep -qx "$TAG" <<<"$REMOTE_TAGS" && die "tag $TAG already exists on origin"
for t in $REMOTE_TAGS; do
    git rev-parse -q --verify "refs/tags/$t" >/dev/null \
        || die "origin has tag $t that is not fetched here; run: git fetch --tags (the build-number check reads every tag)"
done
if command -v gh >/dev/null && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    die "a GitHub release for $TAG already exists"
fi
ok "tree is clean; $TAG is unused"

# 2. The version in project.yml is the version being released, and the build number rose.
MARKETING="$(yml_value MARKETING_VERSION < project.yml)"
BUILD="$(yml_value CURRENT_PROJECT_VERSION < project.yml)"
[[ "$MARKETING" == "$VERSION" ]] \
    || die "project.yml has MARKETING_VERSION '$MARKETING', not '$VERSION'; bump it (and CURRENT_PROJECT_VERSION) and commit"
[[ "$BUILD" =~ ^[0-9]+$ && "$BUILD" -ge 1 ]] || die "CURRENT_PROJECT_VERSION in project.yml must be a positive integer, got '$BUILD'"
FLOOR=0
for t in $(git tag -l 'v[0-9]*'); do
    b="$(git show "$t:project.yml" 2>/dev/null | yml_value CURRENT_PROJECT_VERSION || true)"
    if [[ "$b" =~ ^[0-9]+$ && "$b" -gt "$FLOOR" ]]; then FLOOR="$b"; fi
done
[[ "$BUILD" -gt "$FLOOR" ]] \
    || die "CURRENT_PROJECT_VERSION is $BUILD but an earlier release already used $FLOOR; it must go up every release or Sparkle will not offer the update"
ok "MARKETING_VERSION $MARKETING, CURRENT_PROJECT_VERSION $BUILD (previous releases: up to $FLOOR)"

# 3. Sparkle's sign_update, and a signing key that matches the key the app trusts. A
#    probe is signed now, so a missing key or a password prompt shows up before the
#    build, and verified against the PUBLIC key in Info.plist, the same check an
#    installed copy makes.
SPARKLE_BIN="${SPARKLE_BIN:-}"
if [[ -z "$SPARKLE_BIN" ]]; then
    for d in "$HOME/.local/share/sparkle/2.10.0/bin" \
             "$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin" \
             "$WORK/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"; do
        [[ -x "$d/sign_update" ]] && { SPARKLE_BIN="$d"; break; }
    done
fi
[[ -x "$SPARKLE_BIN/sign_update" ]] \
    || die "Sparkle 2.10.0's sign_update not found; unpack the Sparkle release and set SPARKLE_BIN to its bin/"
PLIST_KEY="$(plist_get "$PLIST_SRC" SUPublicEDKey)"
[[ -n "$PLIST_KEY" ]] || die "SUPublicEDKey is empty in $PLIST_SRC"

# Keep the key out of every child process's environment (xcodebuild, notarytool, ...):
# only ed_sign's own pipe needs it.
[[ -z "${SPARKLE_ED_PRIVATE_FROSTY:-}" ]] || export -n SPARKLE_ED_PRIVATE_FROSTY

ed_sign() { # ed_sign FILE: print the base64 EdDSA signature (see SPARKLE_ED_PRIVATE_FROSTY above)
    if [[ -n "${SPARKLE_ED_PRIVATE_FROSTY:-}" ]]; then
        printf '%s' "$SPARKLE_ED_PRIVATE_FROSTY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$1"
    else
        "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" -p "$1"
    fi
}
PROBE="$(mktemp "${TMPDIR:-/tmp}/frosty-probe.XXXXXX")"
trap 'rm -f "$PROBE"' EXIT
echo "frosty signing probe $VERSION" >"$PROBE"
PROBE_SIG="$(ed_sign "$PROBE")" \
    || die "cannot sign with the EdDSA key (account '$SPARKLE_ACCOUNT', or \$SPARKLE_ED_PRIVATE_FROSTY); backup: the secret SPARKLE_ED_PRIVATE_FROSTY"
swift "$ROOT/scripts/ed25519-verify.swift" "$PLIST_KEY" "$PROBE_SIG" "$PROBE" >/dev/null 2>&1 \
    || die "the signing key does not match SUPublicEDKey in Info.plist ($PLIST_KEY); updates signed with it would be rejected"
ok "Sparkle tools: $SPARKLE_BIN; signing key matches SUPublicEDKey"

# 4. Credentials. Stop rather than invent any.
grep -qF "\"$SIGN_IDENTITY\"" <<<"$(security find-identity -v -p codesigning)" \
    || die "signing identity not in the keychain: $SIGN_IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '$NOTARY_PROFILE' does not work; fix or set NOTARY_PROFILE (this script never creates credentials)"
ok "identity and notary profile '$NOTARY_PROFILE' usable"

if $PUBLISH; then
    command -v gh >/dev/null || die "--publish needs the gh CLI"
    [[ -n "$(git branch -r --contains HEAD 2>/dev/null)" ]] \
        || die "--publish: HEAD ($(git rev-parse --short HEAD)) is not on origin; push it first, the release tag is created there"
fi

# -- Paths ----------------------------------------------------------------------
DIST="$ROOT/dist/$VERSION"
ARCHIVE="$WORK/Frosty.xcarchive"
EXPORT="$WORK/export"
APP="$EXPORT/Frosty.app"
ZIP="$DIST/Frosty-$VERSION-macOS.zip"
DMG="$DIST/Frosty-$VERSION-macOS.dmg"
APPCAST="$DIST/appcast.xml"
rm -rf "$WORK" "$DIST"
mkdir -p "$WORK" "$DIST"

run_quiet() { # run_quiet LOGFILE cmd...: show the tail of the log only on failure
    local log="$1"; shift
    "$@" >"$log" 2>&1 || { tail -40 "$log" >&2; die "failed: $1 $2 (full log: $log)"; }
}

notarize() { # notarize FILE: submit, wait, insist on Accepted
    local file="$1" status id result
    result="$WORK/notary-$(basename "$file").plist"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist >"$result" \
        || { cat "$result" >&2; die "notarytool failed for $(basename "$file")"; }
    status="$(plutil -extract status raw -o - "$result")"; id="$(plutil -extract id raw -o - "$result")"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        die "notarization of $(basename "$file") ended '$status' (submission $id)"
    fi
    ok "notarized $(basename "$file") (submission $id)"
}

# -- Build ----------------------------------------------------------------------
info "Archiving (Developer ID, hardened runtime)"
xcodegen generate --quiet
run_quiet "$WORK/archive.log" xcodebuild archive \
    -project Frosty.xcodeproj -scheme Frosty -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$WORK/DerivedData" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp"

info "Exporting for Developer ID distribution"
cat >"$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
EOF
run_quiet "$WORK/export.log" xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$EXPORT"
[[ -d "$APP" ]] || die "export produced no Frosty.app in $EXPORT"

# The built app says what it is; it must be what was asked for.
INFO="$APP/Contents/Info.plist"
[[ "$(plist_get "$INFO" CFBundleShortVersionString)" == "$VERSION" ]] || die "built app is not version $VERSION"
[[ "$(plist_get "$INFO" CFBundleVersion)" == "$BUILD" ]] || die "built app's CFBundleVersion is not $BUILD"
[[ "$(plist_get "$INFO" SUPublicEDKey)" == "$PLIST_KEY" ]] || die "built app's SUPublicEDKey differs from Frosty/App/Info.plist"
FEED="$(plist_get "$INFO" SUFeedURL)"
[[ "$FEED" == "$(plist_get "$PLIST_SRC" SUFeedURL)" && "$FEED" == https://github.com/$REPO/releases/latest/download/appcast.xml ]] \
    || die "built app's SUFeedURL is '$FEED', not the production https feed"
[[ "$(plist_get "$INFO" SUEnableAutomaticChecks)" == "true" ]] || die "built app has automatic update checks off"
MIN_OS="$(plist_get "$INFO" LSMinimumSystemVersion)"
[[ -n "$MIN_OS" ]] || die "built app has no LSMinimumSystemVersion"
ok "built Frosty $VERSION ($BUILD), feed $FEED"

# Every Mach-O in the app, Sparkle's included, must carry our identity, the hardened
# runtime and a secure timestamp, or notarization rejects the lot.
check_signing() {
    local app="$1" f details count=0
    codesign --verify --deep --strict --verbose=2 "$app" 2>"$WORK/codesign-verify.log" \
        || { cat "$WORK/codesign-verify.log" >&2; die "codesign --verify --deep --strict failed for $app"; }
    while IFS= read -r f; do
        [[ "$(file -b "$f")" == *Mach-O* ]] || continue
        details="$(codesign -dvv "$f" 2>&1)" || die "unsigned code: $f"
        grep -q "^Authority=$SIGN_IDENTITY" <<<"$details" || die "not signed with $SIGN_IDENTITY: $f"
        grep -q "^TeamIdentifier=$TEAM_ID" <<<"$details" || die "wrong team on: $f"
        grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" || die "hardened runtime missing on: $f"
        grep -q "^Timestamp=" <<<"$details" || die "no secure timestamp on: $f"
        count=$((count + 1))
    done < <(find "$app/Contents" -type f)
    ok "signature valid (deep, strict); $count Mach-O files carry Developer ID + hardened runtime + timestamp"
}
check_signing "$APP"

# -- Notarize and staple the app ----------------------------------------------------
info "Notarizing Frosty.app"
ditto -c -k --keepParent "$APP" "$WORK/Frosty-notarize.zip"
notarize "$WORK/Frosty-notarize.zip"
xcrun stapler staple "$APP" >/dev/null
xcrun stapler validate "$APP" >/dev/null
grep -q 'source=Notarized Developer ID' <<<"$(spctl -a -t exec -vv "$APP" 2>&1 || true)" \
    || die "Gatekeeper does not report Frosty.app as Notarized Developer ID"
ok "stapled; Gatekeeper: Notarized Developer ID"

# -- The Sparkle update archive -----------------------------------------------------
info "Zipping the update archive"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# -- The DMG (what people download) --------------------------------------------------
info "Building the DMG"
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Frosty.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Frosty" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG" >/dev/null
xcrun stapler validate "$DMG" >/dev/null
grep -q 'accepted' <<<"$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 || true)" \
    || die "Gatekeeper does not accept the DMG"
ok "DMG signed, notarized, stapled"

# -- Checksums -----------------------------------------------------------------------
(cd "$DIST" && for f in "$(basename "$ZIP")" "$(basename "$DMG")"; do shasum -a 256 "$f" >"$f.sha256"; done)

# -- The appcast ---------------------------------------------------------------------
info "Signing the zip and writing appcast.xml"
ED_SIG="$(ed_sign "$ZIP")"
[[ -n "$ED_SIG" ]] || die "sign_update produced no signature"
LENGTH="$(stat -f%z "$ZIP")"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ENCLOSURE="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")"
cat >"$APPCAST" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Frosty</title>
        <link>https://github.com/$REPO</link>
        <description>Frosty updates</description>
        <language>en</language>
        <item>
            <title>Frosty $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <link>https://github.com/$REPO/releases/tag/$TAG</link>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <enclosure url="$ENCLOSURE" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIG"/>
        </item>
    </channel>
</rss>
EOF
xmllint --noout "$APPCAST" || die "appcast.xml is not well-formed"
ok "appcast.xml written ($ENCLOSURE)"

# -- Verify what will be published ---------------------------------------------------
info "Verifying the staged release"
"$ROOT/scripts/verify-update-feed.sh" "$DIST"

# -- Publish (or print how) --------------------------------------------------------
TARGET="$(git rev-parse HEAD)"
GH_CMD=(gh release create "$TAG"
        "$DMG" "$ZIP" "$DMG.sha256" "$ZIP.sha256" "$APPCAST"
        --repo "$REPO" --target "$TARGET" --title "Frosty $VERSION" --generate-notes)

echo
printf '\033[0;32m=== Frosty %s (build %s) is ready in %s ===\033[0m\n' "$VERSION" "$BUILD" "dist/$VERSION"
ls -1 "$DIST" | sed 's/^/    /'
echo
echo "To publish (creates tag $TAG at ${TARGET:0:10}, which must be pushed to origin first):"
printf '    '; printf '%q ' "${GH_CMD[@]}"; echo
echo
echo "Then confirm the live feed:  scripts/verify-update-feed.sh"

if $PUBLISH; then
    info "--publish: creating the GitHub release"
    "${GH_CMD[@]}"
    ok "published $TAG"
fi
