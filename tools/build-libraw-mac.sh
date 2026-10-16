#!/bin/bash
# Builds LibRaw 0.21.4 shared for x86_64 and arm64 under ~/build/deps on the build Mac.
# Package.swift reads the install prefix from FP_LIBRAW_PREFIX.
#
# WHY THIS EXISTS. Before it, the LibRaw tree was built by hand with no version-min flag, so
# the toolchain defaulted the minimum to the host OS and three builds shipped a dylib
# declaring it needs macOS 26 inside an app declaring it runs on macOS 14. One of two
# external dependencies was reproducible and the other was folklore, and the folklore one
# drifted.
#
# THE DEPLOYMENT TARGET IS THE POINT OF THIS FILE. It is one variable, and it must move
# together with:
#   1. Package.swift            platforms: [.macOS(.vNN)]
#   2. tools/bundle-app.sh      LSMinimumSystemVersion
#   3. tools/build-libjxl-mac.sh  CMAKE_OSX_DEPLOYMENT_TARGET
# Move one without the others and the mismatch simply reappears pointing the other way.
set -euo pipefail

FP_MACOS_MIN="${FP_MACOS_MIN:-14.0}"
VERSION=0.21.4
# Pinned by content, not by tag. A tarball checksum cannot be moved under us the way a git
# tag can. Recorded from libraw.org on 2026-09-20; if upstream ever republishes the archive
# this fails closed rather than building something else.
TARBALL="LibRaw-${VERSION}.tar.gz"
URL="https://www.libraw.org/data/${TARBALL}"
SHA256="6be43f19397e43214ff56aab056bf3ff4925ca14012ce5a1538a172406a09e63"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p ~/build/deps
cd ~/build/deps

if [ ! -f "$TARBALL" ]; then curl -sSLo "$TARBALL" "$URL"; fi
echo "${SHA256}  ${TARBALL}" | shasum -a 256 -c -

for ARCH in x86_64 arm64; do
  # The install directory suffix is NOT the arch flag. The x86 prefix has been
  # `libraw-0.21.4-x86` since it was first built by hand, and FP_LIBRAW_PREFIX in every
  # build command and every brief points at that name. Renaming it here would be a silent
  # break of things this script is not allowed to touch.
  #
  # HOST is the autotools triple and is NOT the clang -arch name either. LibRaw 0.21.4
  # ships a pre-generated `config.sub` stamped 2015-03-08, which predates Apple silicon and
  # rejects `arm64-apple-darwin` outright ("machine `arm64-apple' not recognized"), failing
  # configure before a single file compiles. `aarch64` is the architecture's own name and
  # the one that 2015 config.sub canonicalizes, so the triple says aarch64 while every
  # compile and link flag keeps saying `-arch arm64`, which is the only spelling clang
  # accepts. Two names for one architecture, each required by a different tool.
  case "$ARCH" in
    x86_64) SUFFIX=x86    ; HOST=x86_64-apple-darwin  ;;
    arm64)  SUFFIX=arm64  ; HOST=aarch64-apple-darwin ;;
    *)      echo "FAIL: no configure host triple known for ${ARCH}" >&2; exit 1 ;;
  esac
  OUT="$HOME/build/deps/libraw-${VERSION}-${SUFFIX}"
  SRC="$HOME/build/deps/libraw-src-${SUFFIX}"

  # Keep the working tree until the new one is proven. This dependency is load-bearing for
  # every build of the app, and `rm -rf` on it before the replacement exists means a failed
  # configure leaves the machine unable to build at all. The previous install is moved aside
  # and restored by the trap on any non-zero exit, including the assertions at the end.
  PREV="${OUT}.prev"
  rm -rf "$PREV"
  [ -d "$OUT" ] && mv "$OUT" "$PREV"
  restore() {
    if [ -d "$PREV" ]; then
      echo "restoring the previous ${SUFFIX} install after a failure" >&2
      rm -rf "$OUT"; mv "$PREV" "$OUT"
    fi
  }
  trap restore EXIT

  rm -rf "$SRC"
  mkdir -p "$SRC"
  tar xzf "$TARBALL" -C "$SRC" --strip-components=1

  ( cd "$SRC"
    # The tarball ships a pre-generated `configure`, so no autoreconf and no autotools on
    # the host. Deployment target goes in on BOTH the compile and the link line, and in the
    # environment: autotools honours all three in different places and leaving any one out
    # is how this drifted in the first place.
    export MACOSX_DEPLOYMENT_TARGET="$FP_MACOS_MIN"
    FLAGS="-arch ${ARCH} -mmacosx-version-min=${FP_MACOS_MIN} -O3"
    #
    # THE ARCH GOES IN THE COMPILER DRIVER, not only in CFLAGS, and that is not belt and
    # braces. libtool's darwin path builds a shared library in two steps, and the first one
    # is spelled (libtool.m4, _LT_DARWIN_LINKER_FEATURES):
    #
    #     $CC -r -keep_private_externs -nostdlib -o <lib>-master.o $libobjs
    #
    # with NO flags of any kind appended. Only the second step, the `-dynamiclib`, gets
    # CXXFLAGS. So with the arch living in CXXFLAGS alone, every object compiles as arm64
    # and then `g++ -r` runs at the HOST arch, ignores all 78 of them ("building for
    # macOS-x86_64 but attempting to link with file built for unknown-arm64"), and emits an
    # empty x86_64 master.o. The final `-dynamiclib -arch arm64` then ignores THAT and
    # writes a 16 KB arm64 dylib containing nothing. Putting the arch in $CC is what reaches
    # the reload step, because the reload step interpolates $CC and nothing else.
    #
    # The empty library is correctly formed: right arch, right minos, right install name,
    # and it exports zero symbols. It is the arch and minos assertions below that it sails
    # past, which is why there is now a symbol assertion beside them. Both arches take this
    # path so the two builds stay one code path.
    ./configure \
      --prefix="$OUT" \
      --host="${HOST}" \
      --enable-shared --disable-static \
      --disable-examples \
      --disable-jpeg --disable-jasper --disable-lcms --disable-openmp \
      CC="gcc -arch ${ARCH}" CXX="g++ -arch ${ARCH}" \
      CFLAGS="$FLAGS" CXXFLAGS="$FLAGS" LDFLAGS="-arch ${ARCH} -mmacosx-version-min=${FP_MACOS_MIN}" \
      > "$HOME/build/deps/libraw-configure-${SUFFIX}.log" 2>&1
    make -j8 > "$HOME/build/deps/libraw-build-${SUFFIX}.log" 2>&1
    make install > "$HOME/build/deps/libraw-install-${SUFFIX}.log" 2>&1
  )

  # The bundle expects to load it by @rpath. Set it here rather than fixing it up later in
  # bundle-app.sh, so the library is correct wherever it is consumed from.
  install_name_tool -id "@rpath/libraw_r.23.dylib" "$OUT/lib/libraw_r.23.dylib"

  # PROVE THE OUTPUT, do not assume it. This assertion is the entire reason the file exists:
  # a script that sets a deployment target and never checks it would have drifted exactly as
  # the hand build did.
  GOT=$(otool -l "$OUT/lib/libraw_r.23.dylib" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  if [ "$GOT" != "$FP_MACOS_MIN" ]; then
    echo "FAIL: ${SUFFIX} dylib minos is ${GOT}, expected ${FP_MACOS_MIN}" >&2
    exit 1
  fi
  ARCHS=$(lipo -archs "$OUT/lib/libraw_r.23.dylib")
  if [ "$ARCHS" != "$ARCH" ]; then
    echo "FAIL: ${SUFFIX} dylib is '${ARCHS}', expected '${ARCH}'" >&2
    exit 1
  fi

  # PROVE IT HAS CONTENTS. The two assertions above pass on an EMPTY library: a dylib with
  # no objects in it still reports the right arch, the right minos and the right install
  # name, and weighs 16 KB instead of 1.2 MB. That is exactly what the arm64 cross build
  # produced before the $CC fix above, and the only thing that caught it was the app's link
  # failing several minutes later with "_libraw_unpack, symbol(s) not found". A check that
  # cannot fail on the failure it exists to catch is not a check, so assert the symbols the
  # app actually links against, by name, out of the library that was just installed.
  for SYM in _libraw_init _libraw_open_file _libraw_unpack _libraw_version _libraw_close; do
    if ! nm -gU "$OUT/lib/libraw_r.23.dylib" 2>/dev/null | grep -q " ${SYM}\$"; then
      echo "FAIL: ${SUFFIX} dylib does not export ${SYM}; it built empty." >&2
      echo "      $(ls -l "$OUT/lib/libraw_r.23.dylib" | awk '{print $5}') bytes. A working one is over a megabyte." >&2
      echo "      Look for 'ignoring file ... built for unknown-${ARCH}' in" >&2
      echo "      $HOME/build/deps/libraw-build-${SUFFIX}.log: that is libtool's reload step" >&2
      echo "      losing the arch, and the fix is the arch in CC/CXX, not in CFLAGS." >&2
      exit 1
    fi
  done
  NSYM=$(nm -gU "$OUT/lib/libraw_r.23.dylib" | wc -l | tr -d ' ')
  # Proven, so the previous install is no longer needed and the trap must not fire.
  trap - EXIT
  rm -rf "$PREV"
  echo "== ${SUFFIX}: minos ${GOT}, archs ${ARCHS}, ${NSYM} exported symbols"
  ls "$OUT/lib"/libraw_r*.dylib
done

echo "LIBRAW-DEPS-COMPLETE (deployment target ${FP_MACOS_MIN})"
