#!/usr/bin/env bash
# Write a bundle's Info.plist, with the update keys and the version string for one
# line, per the shared update standard. bundle-app.sh calls this; the test runs it alone.
#
#   tools/write-info-plist.sh <out plist> <exec name> <bundle id> <base version> <build> <git hash> <shipping> <release|beta|none>
#
#   release  the public feed on the site, version "0.1.0"
#   beta     the unlisted feed from the environment, version "0.1.0 beta N"
#   none     no feed, no updater, version "Dev 0.1.0 (122)"; a dev build never checks
#
# Env for the beta line, both required: FP_BETA_FEED_URL (the unlisted feed, which never
# lives in this repository) and FP_BETA_NUMBER (the N above).
set -euo pipefail
OUT="${1:?out plist}"; EXEC_NAME="${2:?exec name}"; BUNDLE_ID="${3:?bundle id}"
BASE="${4:?base version}"; BUILD="${5:?build}"; GIT_HASH="${6:?git hash}"; SHIPPING="${7:?shipping}"; LINE="${8:-none}"

RELEASE_FEED="https://filmpositive.app/updates/appcast.xml"
# The public half of the app's EdDSA key. The private half signs each update and the
# feed, and lives nowhere near this repository.
PUBLIC_ED_KEY="uVDjXdPqEa8+Q5mZKoqr/dy2lXNZcyUw5abOId7MQGI="

case "$LINE" in
    release) FEED="$RELEASE_FEED"; VERSION_STRING="$BASE" ;;
    beta)
        FEED="${FP_BETA_FEED_URL:?the beta line needs FP_BETA_FEED_URL}"
        N="${FP_BETA_NUMBER:?the beta line needs FP_BETA_NUMBER}"
        VERSION_STRING="$BASE beta $N" ;;
    none) FEED=""; VERSION_STRING="Dev $BASE ($BUILD)" ;;
    *) echo "FATAL: update line must be release, beta or none, not '$LINE'" >&2; exit 2 ;;
esac

UPDATE_KEYS=""
if [[ -n "$FEED" ]]; then
    UPDATE_KEYS="	<key>SUFeedURL</key>
	<string>$FEED</string>
	<key>SUPublicEDKey</key>
	<string>$PUBLIC_ED_KEY</string>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
	<key>SURequireSignedFeed</key>
	<true/>
	<key>SUVerifyUpdateBeforeExtraction</key>
	<true/>"
fi

cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Film Positive</string>
	<key>CFBundleExecutable</key>
	<string>$EXEC_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Film Positive</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION_STRING</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>GitHash</key>
	<string>$GIT_HASH</string>
	<key>Shipping</key>
	<$SHIPPING/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.photography</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
${UPDATE_KEYS:+$UPDATE_KEYS
}</dict>
</plist>
PLIST
plutil -lint "$OUT" >/dev/null
echo "    updates:    $LINE ${FEED:-no feed}, version $VERSION_STRING"
