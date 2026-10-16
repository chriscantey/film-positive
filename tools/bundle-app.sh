#!/bin/bash
# tools/bundle-app.sh: wrap the SwiftPM release build into "Film Positive <version> b<n>.app".
#
# Runs on a Mac, from the repo root, after `swift build -c release --product FilmPositive`
# for the arch. Produces a signed app bundle and, on request, a zip:
#
#   Contents/MacOS/Film Positive             the SwiftPM executable, renamed, rpath -> ../Frameworks
#   Contents/Frameworks/libraw_r.23.dylib    the one dynamic dependency (libjxl is static)
#   Contents/Resources/profiles/             the shipped profiles (ProfileLibrary.bundled)
#   Contents/Resources/AppIcon.icns          assets/AppIcon.icns
#   Contents/Info.plist                      bundle id, version and build from AppInfo
#
# An unbundled SwiftPM executable has no bundle identifier, so every build would share one
# preferences domain and folder bookmarks would have no owner.
#
# Usage: tools/bundle-app.sh              (env below; the keychain password comes on stdin
#                                          when FP_SIGN=devid, never on argv)
#   FP_ARCH            x86_64 | arm64 | universal     (default: uname -m)
#   FP_BUILD_DIR       SwiftPM products dir           (default .build/release, or
#                                                      .build-arm64/release for arm64)
#   FP_LIBRAW_PREFIX   LibRaw install prefix          (default ~/build/deps/libraw-0.21.4-<x86|arm64>)
#   FP_OUT             output dir                     (default ~/build/Film Positive)
#   FP_ZIP             1 to also write a zip           (default: no zip)
#   FP_SIGN            devid | adhoc                  (default devid when FP_IDENTITY and
#                                                      FP_SIGN_KEYCHAIN are both set)
#   FP_IDENTITY        codesign identity              (a "Developer ID Application: ..." name)
#   FP_SIGN_KEYCHAIN   keychain holding the identity
#   FP_NOTARY_PROFILE  notarytool keychain profile    (unset = not notarized)
#   FP_SHIPPING        1 for a shipping build: About shows the git hash instead of the build
#                      number
set -euo pipefail
cd "$(dirname "$0")/.."

# FP_ARCH=universal needs both single-arch builds to exist first, then lipo joins them: no
# SwiftPM flag emits a fat binary in one pass.
ARCH="${FP_ARCH:-$(uname -m)}"
case "$ARCH" in
    x86_64)    BUILD_DIR="${FP_BUILD_DIR:-.build/release}"; DEP_SUFFIX=x86 ;;
    arm64)     BUILD_DIR="${FP_BUILD_DIR:-.build-arm64/release}"; DEP_SUFFIX=arm64 ;;
    universal) BUILD_DIR="${FP_BUILD_DIR:-.build/release}"; DEP_SUFFIX=x86
               ARM_BUILD_DIR="${FP_ARM_BUILD_DIR:-.build-arm64/release}"
               ARM_LIBRAW="${FP_ARM_LIBRAW_PREFIX:-$HOME/build/deps/libraw-0.21.4-arm64}" ;;
    *) echo "FATAL: unknown arch $ARCH (x86_64 | arm64 | universal)" >&2; exit 1 ;;
esac
LIBRAW="${FP_LIBRAW_PREFIX:-$HOME/build/deps/libraw-0.21.4-$DEP_SUFFIX}"
# One folder named for the app, holding one bundle per build named
# "<App> <version> b<n>.app".
OUT="${FP_OUT:-$HOME/build/Film Positive}"
SIGN_KEYCHAIN="${FP_SIGN_KEYCHAIN:-}"
IDENTITY="${FP_IDENTITY:-}"
if [[ -z "${FP_SIGN:-}" ]]; then
    if [[ -n "$IDENTITY" && -f "$SIGN_KEYCHAIN" ]]; then FP_SIGN=devid; else FP_SIGN=adhoc; fi
fi
if [[ "$FP_SIGN" == devid ]]; then
    [[ -n "$IDENTITY" ]] || { echo "FATAL: FP_SIGN=devid needs FP_IDENTITY" >&2; exit 1; }
    [[ -f "$SIGN_KEYCHAIN" ]] || { echo "FATAL: FP_SIGN=devid needs FP_SIGN_KEYCHAIN to name a keychain file" >&2; exit 1; }
fi

APP_SRC=Sources/FilmPositive/App/FilmPositiveApp.swift
VERSION=$(grep -oE 'static let version = "[^"]+"' "$APP_SRC" | sed -E 's/.*"([^"]+)"/\1/')
BUILD=$(grep -oE 'static let build = [0-9]+' "$APP_SRC" | grep -oE '[0-9]+$')
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "FATAL: could not read AppInfo from $APP_SRC" >&2; exit 1; }
BUNDLE_ID=co.wonders.filmpositive
# A source tree copied without .git has no hash to read, so FP_GIT_HASH passes it in.
GIT_HASH="${FP_GIT_HASH:-$(git rev-parse --short HEAD 2>/dev/null || echo nogit)}"
SHIPPING=$([[ "${FP_SHIPPING:-0}" == 1 ]] && echo true || echo false)

EXE="$BUILD_DIR/FilmPositive"
DYLIB="$LIBRAW/lib/libraw_r.23.dylib"
PROFILES="$BUILD_DIR/FilmPositive_FilmPositiveCore.bundle/profiles"
for p in "$EXE" "$DYLIB" "$PROFILES/aliases.json" assets/AppIcon.icns; do
    [[ -e "$p" ]] || { echo "FATAL: missing $p" >&2; exit 1; }
done
got_arch=$(lipo -archs "$EXE")
if [[ "$ARCH" == universal ]]; then
    [[ "$got_arch" == "x86_64" ]] || { echo "FATAL: $EXE is $got_arch, wanted x86_64 for the universal join" >&2; exit 1; }
    ARM_EXE="$ARM_BUILD_DIR/FilmPositive"
    ARM_DYLIB="$ARM_LIBRAW/lib/libraw_r.23.dylib"
    for p in "$ARM_EXE" "$ARM_DYLIB"; do
        [[ -e "$p" ]] || { echo "FATAL: missing $p. Build arm64 first:" >&2
                           echo "  FP_LIBRAW_PREFIX=\$HOME/build/deps/libraw-0.21.4-arm64 FP_LIBJXL_PREFIX=\$HOME/build/deps/libjxl-0.12.0-arm64 \\" >&2
                           echo "    swift build -c release --product FilmPositive --arch arm64 --scratch-path .build-arm64" >&2
                           exit 1; }
    done
    arm_arch=$(lipo -archs "$ARM_EXE")
    [[ "$arm_arch" == "arm64" ]] || { echo "FATAL: $ARM_EXE is $arm_arch, wanted arm64" >&2; exit 1; }
    # Both slices must come from the same source, or the app runs one build number's code
    # on one machine and another's on the next, which nothing downstream could detect.
    arm_newer=$(find Sources/FilmPositive Sources/FilmPositiveCore -name '*.swift' -newer "$ARM_EXE" -print -quit)
    [[ -z "$arm_newer" ]] || { echo "FATAL: $ARM_EXE is older than $arm_newer" >&2; exit 1; }
else
    [[ "$got_arch" == "$ARCH" ]] || { echo "FATAL: $EXE is $got_arch, wanted $ARCH" >&2; exit 1; }
fi

# The version and build come from the source and the executable comes from BUILD_DIR, so a
# stale product dir would produce a bundle stamped with a build number it was never compiled
# from. Sources/fpdev is the headless CLI and is not in this bundle, so a change there does
# not block an app build.
newer=$(find Sources/FilmPositive Sources/FilmPositiveCore -name '*.swift' -newer "$EXE" -print -quit)
if [[ -n "$newer" ]]; then
    echo "FATAL: $EXE is older than $newer" >&2
    echo "       BUILD_DIR is $BUILD_DIR. Build into it, or set FP_BUILD_DIR to the dir you built." >&2
    exit 1
fi

# The app's name has a space in it, and so does the executable inside, the way
# Activity Monitor.app/Contents/MacOS/Activity Monitor does. EXEC_NAME is used only for the
# Contents/MacOS filename and CFBundleExecutable. The SwiftPM product name is unchanged.
# A `pgrep -x` for the process needs the spaced name.
EXEC_NAME="Film Positive"
# Only arm64 is labelled, so two architectures of the same build can sit side by side.
SUFFIX=""
[[ "$ARCH" == arm64 ]] && SUFFIX=" (Apple Silicon)"
# A universal build carries no suffix: it IS the ordinary build, and the single-arch names
# exist only for the two cases where one slice is wanted on its own.
APP="$OUT/Film Positive $VERSION b$BUILD$SUFFIX.app"
echo ">> Film Positive $VERSION ($BUILD) $ARCH -> $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

strip_rpaths() {  # every LC_RPATH pointing at a build-tree or toolchain path
    local f="$1" rp
    otool -l "$f" | awk '/LC_RPATH/{getline;getline;print $2}' | while read -r rp; do
        case "$rp" in
            /Users/*|/Applications/*|/opt/*|/usr/local/*) install_name_tool -delete_rpath "$rp" "$f" ;;
        esac
    done
}

# On a FAT binary `otool -l` lists the rpaths of BOTH slices and `install_name_tool
# -delete_rpath` then fails on whichever slice does not carry the one being removed: the
# x86 half points at libraw-0.21.4-x86 and the arm64 half at libraw-0.21.4-arm64. So the
# rpath surgery happens on each slice BEFORE they are joined, and the shared block below
# skips a universal build.
if [[ "$ARCH" == universal ]]; then
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    cp "$EXE" "$TMP/exe-x86"; cp "$ARM_EXE" "$TMP/exe-arm"
    for f in "$TMP/exe-x86" "$TMP/exe-arm"; do
        chmod u+w "$f"
        strip_rpaths "$f"
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$f"
    done
    lipo -create "$TMP/exe-x86" "$TMP/exe-arm" -output "$APP/Contents/MacOS/$EXEC_NAME"

    cp -L "$DYLIB" "$TMP/lib-x86"; cp -L "$ARM_DYLIB" "$TMP/lib-arm"
    for f in "$TMP/lib-x86" "$TMP/lib-arm"; do
        chmod u+w "$f"
        strip_rpaths "$f"
        install_name_tool -id "@rpath/libraw_r.23.dylib" "$f"
    done
    # The dylib has to be fat too. A universal executable loading a single-arch dylib fails
    # at launch on the arch the dylib lacks, which is the one machine you did not test on.
    lipo -create "$TMP/lib-x86" "$TMP/lib-arm" -output "$APP/Contents/Frameworks/libraw_r.23.dylib"
else
    cp "$EXE" "$APP/Contents/MacOS/$EXEC_NAME"
    cp -L "$DYLIB" "$APP/Contents/Frameworks/libraw_r.23.dylib"
fi
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"
chmod u+w "$APP/Contents/Frameworks/libraw_r.23.dylib"

# Sparkle, the update framework, built by SwiftPM beside the executable as a binary
# framework (universal as shipped, so one copy serves every FP_ARCH). The whole framework
# goes in, XPC services and helpers inside; tools/sign-framework.sh signs it inside out.
SRC_FW="$(dirname "$EXE")/Sparkle.framework"
[[ -d "$SRC_FW" ]] || { echo "FATAL: $SRC_FW not found beside the executable (swift build puts it there)" >&2; exit 1; }
cp -R "$SRC_FW" "$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Resources/Licenses"
cp licenses/sparkle-LICENSE.txt "$APP/Contents/Resources/Licenses/sparkle-LICENSE.txt"
cp -R "$PROFILES" "$APP/Contents/Resources/profiles"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Info.plist, with the update keys and the version string for the update line:
# FP_UPDATE_LINE=release|beta|none (default none, a dev build that never checks).
# Per the shared update standard. tools/write-info-plist.sh is tested alone.
UPDATE_LINE="${FP_UPDATE_LINE:-none}"
bash tools/write-info-plist.sh "$APP/Contents/Info.plist" "$EXEC_NAME" "$BUNDLE_ID" "$VERSION" "$BUILD" "$GIT_HASH" "$SHIPPING" "$UPDATE_LINE"

echo ">> rpaths: the build host's paths out, @executable_path/../Frameworks in"
if [[ "$ARCH" != universal ]]; then
strip_rpaths "$APP/Contents/MacOS/$EXEC_NAME"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXEC_NAME"
strip_rpaths "$APP/Contents/Frameworks/libraw_r.23.dylib"
install_name_tool -id "@rpath/libraw_r.23.dylib" "$APP/Contents/Frameworks/libraw_r.23.dylib"
fi

if otool -L "$APP/Contents/MacOS/$EXEC_NAME" "$APP/Contents/Frameworks/libraw_r.23.dylib" | grep -qE '^\s+/(Users|opt|usr/local)/'; then
    echo "FATAL: a load command still points at the build host:" >&2
    otool -L "$APP/Contents/MacOS/$EXEC_NAME" "$APP/Contents/Frameworks/libraw_r.23.dylib" | grep -E '^\s+/(Users|opt|usr/local)/' >&2
    exit 1
fi

echo ">> codesign ($FP_SIGN)"
sign_one() {  # retry x3: Sequoia codesign has a transient CS-subsystem race
    local f="$1" attempt
    for attempt in 1 2 3; do
        codesign --force --sign "$SIGN_ID" ${SIGN_EXTRA[@]+"${SIGN_EXTRA[@]}"} "$f" 2>/dev/null && return 0
        sleep 0.5
    done
    codesign --force --sign "$SIGN_ID" ${SIGN_EXTRA[@]+"${SIGN_EXTRA[@]}"} "$f"
}
SIGN_EXTRA=()
if [[ "$FP_SIGN" == devid ]]; then
    IFS= read -r SIGN_PW
    [[ "$SIGN_PW" != *$'\n'* ]] || { echo "FATAL: the keychain password holds a newline" >&2; exit 3; }
    # The password goes to `security -i` on stdin, never into an argv that
    # another process could read. `security -i` takes one command per line and
    # a double-quoted argument with backslash escapes.
    sec_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }
    printf 'unlock-keychain -p %s %s\n' "$(sec_quote "$SIGN_PW")" "$(sec_quote "$SIGN_KEYCHAIN")" \
        | security -i
    unset SIGN_PW
    security set-keychain-settings "$SIGN_KEYCHAIN"     # no auto-lock mid-run
    SIGN_ID="$IDENTITY"
    # Hardened runtime plus a secure timestamp on every binary: Apple's notary service
    # rejects a submission without both.
    SIGN_EXTRA=(--keychain "$SIGN_KEYCHAIN" --options runtime --timestamp)
else
    SIGN_ID="-"
fi
# The shared signer (_AppUpdates/Tools/SignFramework.sh, vendored unchanged) takes
# extra codesign arguments after the framework name; a Developer ID identity in
# its own keychain needs the keychain named.
FW_EXTRA=(); [[ "$FP_SIGN" == devid ]] && FW_EXTRA=(--keychain "$SIGN_KEYCHAIN")
bash tools/sign-framework.sh "$SIGN_ID" "$APP" Sparkle.framework "${FW_EXTRA[@]+"${FW_EXTRA[@]}"}"
sign_one "$APP/Contents/Frameworks/libraw_r.23.dylib"
sign_one "$APP"

echo ">> verify"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "$ARCH" == universal ]]; then
    # Assert the fat binary actually holds both slices rather than trusting that lipo ran.
    for f in "$APP/Contents/MacOS/$EXEC_NAME" "$APP/Contents/Frameworks/libraw_r.23.dylib"; do
        slices=$(lipo -archs "$f")
        [[ "$slices" == *x86_64* && "$slices" == *arm64* ]] \
            || { echo "FATAL: $(basename "$f") is [$slices], wanted both" >&2; exit 1; }
        echo "OK  $(basename "$f"): $slices"
    done
fi

# No bundled library may demand a newer macOS than the app claims to run on. A library built
# with no version-min flag takes the build host's OS as its minimum, and the linker only
# warns, so this is the gate.
#
# Checked per SLICE, not per file: a universal binary can disagree with itself, and `otool -l`
# on a fat file prints one load command per architecture.
APP_MIN=$(otool -l "$APP/Contents/MacOS/$EXEC_NAME" \
    | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; f=0}' | sort -V | head -1)
if [[ -n "$APP_MIN" ]]; then
    for lib in "$APP/Contents/Frameworks/"*.dylib; do
        [[ -e "$lib" ]] || continue
        while read -r libmin; do
            [[ -n "$libmin" ]] || continue
            # sort -V puts the lower version first; if the library's minimum is not the lower
            # of the pair then it is asking for an OS the app says it does not need.
            lower=$(printf '%s\n%s\n' "$APP_MIN" "$libmin" | sort -V | head -1)
            if [[ "$lower" != "$libmin" ]]; then
                echo "FATAL: $(basename "$lib") needs macOS $libmin but the app declares $APP_MIN." >&2
                echo "       Rebuild it with tools/build-libraw-mac.sh, or raise the app's minimum." >&2
                echo "       The three that must move together: Package.swift platforms," >&2
                echo "       LSMinimumSystemVersion here, and the dependency build scripts." >&2
                exit 1
            fi
        done < <(otool -l "$lib" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; f=0}')
        echo "OK  $(basename "$lib"): minos within the app's $APP_MIN"
    done
fi
echo "OK  $APP"

# Notarize and staple, so Gatekeeper opens the app on any Mac. Gated on FP_NOTARY_PROFILE, a
# notarytool keychain profile stored in the signing keychain. Apple usually answers in one to
# three minutes. On a rejection, read the log before resubmitting:
# `xcrun notarytool log <submission id> --keychain-profile "$FP_NOTARY_PROFILE"
# --keychain "$SIGN_KEYCHAIN"`.
if [[ -n "${FP_NOTARY_PROFILE:-}" && "$FP_SIGN" == devid ]]; then
    echo ">> notarize + staple ($FP_NOTARY_PROFILE)"
    NZIP="$(mktemp -d)/notarize.zip"
    ditto -c -k --keepParent "$APP" "$NZIP"
    xcrun notarytool submit "$NZIP" --keychain-profile "$FP_NOTARY_PROFILE" \
        --keychain "$SIGN_KEYCHAIN" --wait
    xcrun stapler staple "$APP"
    rm -f "$NZIP"
elif [[ "$FP_SIGN" == devid ]]; then
    echo "!!  not notarized: FP_NOTARY_PROFILE is unset"
fi
echo "    codesign:   $(codesign --verify --strict "$APP" 2>&1 && echo valid || echo FAILED)"
echo "    notarized:  $(xcrun stapler validate "$APP" >/dev/null 2>&1 && echo 'stapled' || echo 'no ticket')"
echo "    gatekeeper: $(spctl -a -t exec -vv "$APP" 2>&1 | awk -F'=' '/source/{print $2; exit}')"

if [[ "${FP_ZIP:-0}" == 1 ]]; then
    ZIP="$OUT/Film Positive $VERSION b$BUILD$SUFFIX.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "OK  $ZIP ($(du -h "$ZIP" | cut -f1))"
fi
