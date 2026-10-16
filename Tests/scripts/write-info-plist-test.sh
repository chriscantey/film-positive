#!/usr/bin/env bash
# tools/write-info-plist.sh writes exactly the update keys each line calls for, and the
# version string, and nothing on the dev line. Runs on a Mac (PlistBuddy).
set -euo pipefail
cd "$(dirname "$0")/../.."
PB=/usr/libexec/PlistBuddy
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P="$T/Info.plist"
fail=0
say() { printf '%s\n' "$*"; }
check() { if [[ "$2" == "$3" ]]; then say "ok   $1"; else say "FAIL $1: got '$2', want '$3'"; fail=1; fi; }
get() { "$PB" -c "Print :$1" "$P" 2>/dev/null || echo "<absent>"; }
run() { bash tools/write-info-plist.sh "$P" "Film Positive" co.wonders.filmpositive 0.1.0 122 abc1234 true "$@" >/dev/null; }

run release
check "release feed"     "$(get SUFeedURL)" "https://filmpositive.app/updates/appcast.xml"
check "release key"      "$(get SUPublicEDKey)" "uVDjXdPqEa8+Q5mZKoqr/dy2lXNZcyUw5abOId7MQGI="
check "release interval" "$(get SUScheduledCheckInterval)" "86400"
check "release signed"   "$(get SURequireSignedFeed)" "true"
check "release verify"   "$(get SUVerifyUpdateBeforeExtraction)" "true"
check "release no auto"  "$(get SUEnableAutomaticChecks)" "<absent>"
check "release version"  "$(get CFBundleShortVersionString)" "0.1.0"
check "release build"    "$(get CFBundleVersion)" "122"

FP_BETA_FEED_URL="https://example.test/x/beta.xml" FP_BETA_NUMBER=2 run beta
check "beta feed"        "$(get SUFeedURL)" "https://example.test/x/beta.xml"
check "beta version"     "$(get CFBundleShortVersionString)" "0.1.0 beta 2"

if FP_BETA_NUMBER=2 run beta 2>/dev/null; then say "FAIL beta without a feed URL was accepted"; fail=1; else say "ok   beta refuses without FP_BETA_FEED_URL"; fi

run none
check "none feed"        "$(get SUFeedURL)" "<absent>"
check "none key"         "$(get SUPublicEDKey)" "<absent>"
check "none verify"      "$(get SUVerifyUpdateBeforeExtraction)" "<absent>"
check "none version"     "$(get CFBundleShortVersionString)" "Dev 0.1.0 (122)"
check "none shipping"    "$(get Shipping)" "true"

if run nightly 2>/dev/null; then say "FAIL an unknown line was accepted"; fail=1; else say "ok   unknown line refused"; fi

[[ "$fail" == 0 ]] && say "write-info-plist: all checks passed" || { say "write-info-plist: FAILED"; exit 1; }
