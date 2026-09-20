#!/usr/bin/env bash
set -euo pipefail

PREFIX="${ANDROID_DEPS_PREFIX:?ANDROID_DEPS_PREFIX must be set to a CI-owned staging prefix}"
NDK_ROOT="${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must point to the Android NDK}"
API="${ANDROID_API:-30}"
ABI="${ANDROID_ABI:-arm64-v8a}"
TARGET="aarch64-linux-android"
JOBS="${BUILD_JOBS:-$(nproc)}"
SOURCE_DIR="${ANDROID_DEPS_SOURCE_DIR:-${RUNNER_TEMP:-/tmp}/bygdok-android-deps-src}"
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
HOST_TAG="linux-x86_64"

mkdir -p "$PREFIX" "$SOURCE_DIR" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/mysql/bin" "$PREFIX/mysql/include"
rm -f "$PREFIX/.build-complete"

export PATH="$TOOLCHAIN/bin:$PATH"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export CC="$TOOLCHAIN/bin/${TARGET}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TARGET}${API}-clang++"
export CFLAGS="-fPIC"
export CXXFLAGS="-fPIC"
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib"

download() {
    local url="$1" name="$2"
    local archive="$SOURCE_DIR/$name"
    if [ ! -f "$archive" ]; then
        curl --fail --location --retry 3 --output "$archive" "$url"
    fi
    printf '%s\n' "$archive"
}

extract() {
    local archive="$1" directory="$2"
    if [ ! -d "$SOURCE_DIR/$directory" ]; then
        case "$archive" in
            *.tar.gz|*.tgz) tar -xzf "$archive" -C "$SOURCE_DIR" ;;
            *.tar.xz) tar -xJf "$archive" -C "$SOURCE_DIR" ;;
            *.tar.bz2) tar -xjf "$archive" -C "$SOURCE_DIR" ;;
            *) echo "Unsupported source archive: $archive" >&2; exit 1 ;;
        esac
    fi
    printf '%s\n' "$SOURCE_DIR/$directory"
}

cmake_build() {
    local source="$1" build="$2"
    shift 2
    cmake -S "$source" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" "$@"
    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"
}

build_zlib() {
    local archive source
    archive="$(download https://zlib.net/fossils/zlib-1.3.1.tar.gz zlib-1.3.1.tar.gz)"
    source="$(extract "$archive" zlib-1.3.1)"
    if [ ! -f "$PREFIX/lib/libz.so" ]; then
        cmake_build "$source" "$SOURCE_DIR/zlib-build" -DBUILD_SHARED_LIBS=ON
    fi
}

build_openssl() {
    local archive source
    archive="$(download https://www.openssl.org/source/old/3.0/openssl-3.0.15.tar.gz openssl-3.0.15.tar.gz)"
    source="$(extract "$archive" openssl-3.0.15)"
    if [ ! -f "$PREFIX/lib/libssl.so" ]; then
        pushd "$source" >/dev/null
        ./Configure android-arm64 -D__ANDROID_API__="$API" --prefix="$PREFIX" --openssldir="$PREFIX/ssl" shared no-tests
        make -j"$JOBS"
        make install_sw
        popd >/dev/null
    fi
}

build_xz() {
    local archive source
    archive="$(download https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz xz-5.6.3.tar.xz)"
    source="$(extract "$archive" xz-5.6.3)"
    if [ ! -f "$PREFIX/lib/liblzma.so" ]; then
        pushd "$source" >/dev/null
        ./configure --host="$TARGET" --prefix="$PREFIX" --disable-static --enable-shared --disable-doc
        make -j"$JOBS"
        make install
        popd >/dev/null
    fi
}

build_ncurses() {
    local archive source
    archive="$(download https://invisible-mirror.net/archives/ncurses/ncurses-6.5.tar.gz ncurses-6.5.tar.gz)"
    source="$(extract "$archive" ncurses-6.5)"
    if [ ! -f "$PREFIX/lib/libncursesw.so" ]; then
        pushd "$source" >/dev/null
        ./configure --host="$TARGET" --prefix="$PREFIX" --with-shared --without-debug --without-ada --without-tests --enable-widec --disable-stripping
        make -j"$JOBS"
        make install
        popd >/dev/null
    fi
    ln -sf libncursesw.so "$PREFIX/lib/libncurses.so"
}

build_readline() {
    local archive source
    archive="$(download https://ftp.gnu.org/gnu/readline/readline-8.2.tar.gz readline-8.2.tar.gz)"
    source="$(extract "$archive" readline-8.2)"
    if [ ! -f "$PREFIX/lib/libreadline.so" ]; then
        pushd "$source" >/dev/null
        ./configure --host="$TARGET" --prefix="$PREFIX" --disable-static --enable-shared \
            bash_cv_wcwidth_broken=no \
            CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
        make -j"$JOBS"
        make install
        popd >/dev/null
    fi
}

build_bzip2() {
    local archive source
    archive="$(download https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz bzip2-1.0.8.tar.gz)"
    source="$(extract "$archive" bzip2-1.0.8)"
    if [ ! -f "$PREFIX/lib/libbz2.so" ]; then
        pushd "$source" >/dev/null
        make -f Makefile-libbz2_so CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="-fPIC"
        cp -f libbz2.so.* "$PREFIX/lib/"
        ln -sf "$(basename "$(find "$PREFIX/lib" -name 'libbz2.so.*' -type f | head -n 1)")" "$PREFIX/lib/libbz2.so"
        cp -f bzlib.h "$PREFIX/include/"
        popd >/dev/null
    fi
}

build_boost() {
    local archive source
    archive="$(download https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.gz boost_1_85_0.tar.gz)"
    source="$(extract "$archive" boost_1_85_0)"
    if [ ! -f "$PREFIX/lib/libboost_filesystem.a" ]; then
        pushd "$source" >/dev/null
        ./bootstrap.sh --with-libraries=filesystem,program_options,iostreams,regex,thread,atomic,container,chrono,date_time
        ./b2 -j"$JOBS" --prefix="$PREFIX" \
            toolset=clang target-os=android architecture=arm address-model=64 \
            cxxflags="--target=$TARGET$API -fPIC -I$PREFIX/include" \
            link=static runtime-link=shared threading=multi install
        popd >/dev/null
    fi
}

build_mariadb() {
    local source
    source="$(extract "$(download https://archive.mariadb.org/connector-c-3.3.8/mariadb-connector-c-3.3.8-src.tar.gz mariadb-connector-c-3.3.8-src.tar.gz)" mariadb-connector-c-3.3.8-src)"
    if [ ! -f "$PREFIX/mysql/lib/mariadb/libmariadb.so" ] && [ ! -f "$PREFIX/mysql/lib/libmariadb.so" ]; then
        cmake_build "$source" "$SOURCE_DIR/mariadb-build" \
            -DCMAKE_INSTALL_PREFIX="$PREFIX/mysql" \
            -DWITH_SSL=OPENSSL -DWITH_EXTERNAL_ZLIB=ON \
            -DOPENSSL_ROOT_DIR="$PREFIX" -DZLIB_ROOT="$PREFIX" \
            -DWITH_CURL=OFF -DWITH_UNIT_TESTS=OFF -DWITH_MSI=OFF
    fi
    local library
    library="$(find "$PREFIX/mysql/lib" -name libmariadb.so -type f -print -quit)"
    test -n "$library" || { echo 'MariaDB Connector/C did not install libmariadb.so' >&2; exit 1; }
    cp -f "$library" "$PREFIX/lib/libmariadb.so"
    cp -R "$PREFIX/mysql/include/." "$PREFIX/include/"
    cat > "$PREFIX/mysql/bin/mysql_config" <<EOF
#!/usr/bin/env sh
case "\${1:-}" in
  --include|--cflags) printf '%s\n' '-I$PREFIX/include' ;;
  --libs|--libs_r) printf '%s\n' '-L$PREFIX/lib -lmariadb -lssl -lcrypto -lz -llzma' ;;
  --version) printf '%s\n' '8.0.36' ;;
  *) printf '%s\n' 'Usage: mysql_config [--include|--cflags|--libs|--libs_r|--version]' >&2; exit 1 ;;
esac
EOF
    chmod +x "$PREFIX/mysql/bin/mysql_config"
}

build_zlib
build_openssl
build_xz
build_ncurses
build_readline
build_bzip2
build_boost
build_mariadb

cp -f "$TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$PREFIX/lib/"
cp -f "$TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/libunwind.so" "$PREFIX/lib/" 2>/dev/null || true

test -f "$PREFIX/mysql/bin/mysql_config"
test -f "$PREFIX/include/mysql.h" || test -f "$PREFIX/include/mariadb/mysql.h"
test -f "$PREFIX/lib/libmariadb.so"
test -f "$PREFIX/lib/libssl.so"
test -f "$PREFIX/lib/libcrypto.so"
test -f "$PREFIX/lib/libreadline.so"
test -f "$PREFIX/lib/libncurses.so"
touch "$PREFIX/.build-complete"