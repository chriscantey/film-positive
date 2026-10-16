#!/bin/bash
# Builds libjxl 0.12.0 static for x86_64 and arm64 under ~/build/deps on the build Mac
# (BSD-3-Clause, highway and brotli only, skcms for color). Run once per host; Package.swift
# reads the install prefix from FP_LIBJXL_PREFIX.
set -e
cd ~/build/deps
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Homebrew CMake (4.x). The portable CMake.app 3.31.5 this used to put first on PATH was retired
# 2026-09-28 after Homebrew CMake 4.4.3 built libjxl 0.12.0 x86_64 cleanly with the same flags.
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
cmake --version | head -1
cd libjxl
git fetch --depth 1 origin tag v0.12.0 2>&1 | tail -1
git checkout -q v0.12.0
git submodule update --init --depth 1 third_party/highway third_party/brotli third_party/skcms 2>&1 | tail -2
git describe --tags
cd ..
for ARCH in x86_64 arm64; do
  OUT=$HOME/build/deps/libjxl-0.12.0-$ARCH
  rm -rf jxl-build-$ARCH "$OUT"
  cmake -S libjxl -B jxl-build-$ARCH -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
    -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_FUZZERS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_GIF=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=TRUE -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF \
    -DCMAKE_INSTALL_PREFIX="$OUT" > jxl-configure-$ARCH.log 2>&1
  cmake --build jxl-build-$ARCH -j8 --target jxl jxl_threads > jxl-build-$ARCH.log 2>&1
  cmake --install jxl-build-$ARCH > jxl-install-$ARCH.log 2>&1 || true
  echo "== $ARCH installed:"; ls "$OUT"/lib 2>/dev/null; ls "$OUT"/include/jxl 2>/dev/null | head -5
  for f in "$OUT"/lib/*.a; do lipo -info "$f" 2>/dev/null | tail -1; done
done
echo "JXL-DEPS-COMPLETE"
