#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${ANDROID_DEPS_PREFIX:?ANDROID_DEPS_PREFIX must point to staged Android dependencies}"
NDK_ROOT="${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must point to the Android NDK}"
API="${ANDROID_API:-30}"
ABI="${ANDROID_ABI:-arm64-v8a}"
JOBS="${BUILD_JOBS:-$(nproc)}"
SOURCE_DIR="${MARIADB_SOURCE_DIR:-${RUNNER_TEMP:-/tmp}/bygdok-mariadb-src}"
OUTPUT_DIR="${MARIADB_RUNTIME_OUTPUT_DIR:-${REPO_DIR}/runtime/build/mariadb-arm64}"
PATCH_DIR="$REPO_DIR/patches/mariadb-10.11.9"
VERSION="10.11.9"
SOURCE_SHA256="0a00180864cd016187c986faab8010de23a117b9a75f91d6456421f894e48d20"
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
READELF="$TOOLCHAIN/bin/llvm-readelf"

for required in \
    "$PREFIX/lib/libssl.so" \
    "$PREFIX/lib/libcrypto.so" \
    "$PREFIX/lib/libz.so" \
    "$PREFIX/lib/libpcre2-8.so" \
    "$PREFIX/lib/libreadline.so" \
    "$PREFIX/lib/libncurses.so" \
    "$PATCH_DIR/android-compat.h"; do
    test -e "$required" || { echo "Missing MariaDB build dependency: $required" >&2; exit 1; }
done

archive="$SOURCE_DIR/mariadb-$VERSION.tar.gz"
source="$SOURCE_DIR/mariadb-$VERSION"
host_build="$SOURCE_DIR/mariadb-host-build"
build="$SOURCE_DIR/mariadb-server-build"
host_import="$host_build/import_executables.cmake"

mkdir -p "$SOURCE_DIR"
if [ ! -s "$archive" ]; then
    curl --fail --location --retry 3 \
        --output "$archive" \
        "https://archive.mariadb.org/mariadb-$VERSION/source/mariadb-$VERSION.tar.gz"
fi
echo "$SOURCE_SHA256  $archive" | sha256sum --check --status || {
    rm -f "$archive"
    echo "MariaDB source checksum failed: $archive" >&2
    exit 1
}

rm -rf "$source" "$host_build" "$build" "$OUTPUT_DIR"
tar -xzf "$archive" -C "$SOURCE_DIR"
for patch_file in "$PATCH_DIR"/*.patch; do
    echo "[mariadb] Applying $(basename "$patch_file")"
    git -C "$source" apply --ignore-space-change "$patch_file"
done

host_curses_library="$(find /usr/lib -name 'libncursesw.so*' -o -name 'libncurses.so*' 2>/dev/null | head -n1)"
test -n "$host_curses_library" || { echo "System libncurses not found; install libncurses-dev" >&2; exit 1; }

env -u CC -u CXX -u AR -u RANLIB -u STRIP -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    cmake -S "$source" -B "$host_build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_SSL=bundled \
        -DWITH_READLINE=OFF \
        -DCURSES_LIBRARY="$host_curses_library" \
        -DCURSES_INCLUDE_PATH=/usr/include \
        -DWITH_UNIT_TESTS=OFF \
        -DWITH_WSREP=OFF \
        -DPLUGIN_COLUMNSTORE=NO \
        -DPLUGIN_DAEMON_EXAMPLE=NO \
        -DCONNECT_WITH_JDBC=OFF \
        -DCONNECT_WITH_MONGO=OFF
cmake --build "$host_build" --target import_executables --parallel "$JOBS"
test -s "$host_import" || { echo "MariaDB native import file was not generated: $host_import" >&2; exit 1; }

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

cmake -S "$source" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_LIBRARY_PATH="$PREFIX/lib" \
    -DCMAKE_EXE_LINKER_FLAGS="-L$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib" \
    -DCMAKE_MODULE_LINKER_FLAGS="-L$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX/server" \
    -DIMPORT_EXECUTABLES="$host_import" \
    -DBUILD_CONFIG=mysql_release \
    -DMYSQL_MAINTAINER_MODE=NO \
    -DHAVE_SYSTEM_LIBFMT_EXITCODE=0 \
    -DHAVE_UCONTEXT_H=False \
    -DSTACK_DIRECTION=-1 \
    -DSTAT_EMPTY_STRING_BUG_EXITCODE=0 \
    -DLSTAT_FOLLOWS_SLASHED_SYMLINK_EXITCODE=0 \
    -DMASK_LONGDOUBLE_EXITCODE=1 \
    -DWITH_SSL=system \
    -DOPENSSL_ROOT_DIR="$PREFIX" \
    -DWITH_ZLIB=system \
    -DZLIB_ROOT="$PREFIX" \
    -DWITH_PCRE=system \
    -DWITH_READLINE=OFF \
    -DREADLINE_INCLUDE_DIR="$PREFIX/include" \
    -DREADLINE_LIBRARY="$PREFIX/lib/libreadline.so" \
    -DCURSES_INCLUDE_PATH="$PREFIX/include" \
    -DCURSES_INCLUDE_DIR="$PREFIX/include" \
    -DCURSES_LIBRARY="$PREFIX/lib/libncurses.so" \
    -DHAVE_TERM_H=1 \
    -DWITH_WSREP=OFF \
    -DWITH_JEMALLOC=OFF \
    -DWITH_MARIABACKUP=OFF \
    -DWITH_UNIT_TESTS=OFF \
    -DWITH_EMBEDDED_SERVER=OFF \
    -DWITH_INNODB_BZIP2=OFF \
    -DWITH_INNODB_LZ4=OFF \
    -DWITH_INNODB_LZMA=ON \
    -DWITH_INNODB_LZO=OFF \
    -DWITH_INNODB_SNAPPY=OFF \
    -DPLUGIN_AUTH_GSSAPI_CLIENT=OFF \
    -DPLUGIN_AUTH_GSSAPI=NO \
    -DPLUGIN_AUTH_PAM=NO \
    -DPLUGIN_CONNECT=NO \
    -DPLUGIN_COLUMNSTORE=NO \
    -DPLUGIN_DAEMON_EXAMPLE=NO \
    -DPLUGIN_EXAMPLE=NO \
    -DPLUGIN_GSSAPI=OFF \
    -DPLUGIN_ROCKSDB=NO \
    -DPLUGIN_TOKUDB=NO \
    -DPLUGIN_SERVER_AUDIT=NO \
    -DCONNECT_WITH_JDBC=OFF \
    -DCONNECT_WITH_MONGO=OFF \
    -DCMAKE_C_FLAGS="-include $PATCH_DIR/android-compat.h" \
    -DCMAKE_CXX_FLAGS="-include $PATCH_DIR/android-compat.h -D__ANDROID__"

cmake --build "$build" --target mariadbd mariadb --parallel "$JOBS"

mariadbd="$(find "$build" -type f -name mariadbd -print -quit)"
mariadb="$(find "$build" -type f -name mariadb -print -quit)"
test -n "$mariadbd" || { echo "MariaDB build did not produce mariadbd" >&2; exit 1; }
test -n "$mariadb" || { echo "MariaDB build did not produce mariadb CLI" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/share"
cp -f "$mariadbd" "$OUTPUT_DIR/bin/mariadbd"
cp -f "$mariadb" "$OUTPUT_DIR/bin/mariadb"
chmod +x "$OUTPUT_DIR/bin/mariadbd" "$OUTPUT_DIR/bin/mariadb"

share_copied=false
for share_dir in "$build/sql/share" "$source/sql/share"; do
    test -n "$(find "$share_dir" -type f -print -quit 2>/dev/null)" || continue
    cp -R "$share_dir/." "$OUTPUT_DIR/share/"
    share_copied=true
done
test "$share_copied" = true || { echo "MariaDB share data was not generated" >&2; exit 1; }
for sql_file in \
    "$source/scripts/mysql_system_tables.sql" \
    "$source/scripts/mysql_performance_tables.sql" \
    "$source/scripts/mysql_system_tables_data.sql" \
    "$source/scripts/fill_help_tables.sql" \
    "$build/scripts/maria_add_gis_sp_bootstrap.sql" \
    "$build/scripts/mysql_sys_schema.sql"; do
    test -f "$sql_file" || { echo "Missing MariaDB bootstrap SQL: $sql_file" >&2; exit 1; }
    cp -f "$sql_file" "$OUTPUT_DIR/share/"
done

pending=("$OUTPUT_DIR/bin/mariadbd" "$OUTPUT_DIR/bin/mariadb")
checked=()
while [ "${#pending[@]}" -gt 0 ]; do
    binary="${pending[0]}"
    pending=("${pending[@]:1}")
    checked+=("$binary")
    while read -r library; do
        case "$library" in
            libc.so|libdl.so|liblog.so|libm.so|libandroid.so|libc++abi.so) continue ;;
        esac
        destination="$OUTPUT_DIR/lib/$library"
        if [ ! -f "$destination" ]; then
            found="$(find "$PREFIX/lib" "$TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android" -name "$library" \( -type f -o -type l \) -print -quit)"
            test -n "$found" || { echo "Missing runtime library $library required by $binary" >&2; exit 1; }
            cp -L "$found" "$destination"
        fi
        already_checked=false
        for checked_file in "${checked[@]}"; do
            [ "$checked_file" = "$destination" ] && already_checked=true
        done
        if [ "$already_checked" = false ]; then
            pending+=("$destination")
        fi
    done < <("$READELF" -d "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | sort -u)
done

for versioned_library in "$OUTPUT_DIR"/lib/lib*.so.*; do
    test -e "$versioned_library" || continue
    versioned_name="$(basename "$versioned_library")"
    unversioned_name="${versioned_name%%.so.*}.so"
    unversioned_library="$OUTPUT_DIR/lib/$unversioned_name"
    mv -f "$versioned_library" "$unversioned_library"
    patchelf --set-soname "$unversioned_name" "$unversioned_library"
    for elf_file in "$OUTPUT_DIR"/bin/* "$OUTPUT_DIR"/lib/*; do
        test -f "$elf_file" || continue
        if "$READELF" -d "$elf_file" 2>/dev/null | grep -q "Shared library: \[$versioned_name\]"; then
            patchelf --replace-needed "$versioned_name" "$unversioned_name" "$elf_file"
        fi
    done
done

for binary in "$OUTPUT_DIR/bin/mariadbd" "$OUTPUT_DIR/bin/mariadb"; do
    file "$binary" | grep -Eq 'ARM aarch64|ARM64' || { echo "Not an AArch64 binary: $binary" >&2; exit 1; }
    "$READELF" -h "$binary" | grep -q 'Machine:.*AArch64' || { echo "ELF machine is not AArch64: $binary" >&2; exit 1; }
    if "$READELF" -l "$binary" | grep -q 'Requesting program interpreter'; then
        "$READELF" -l "$binary" | grep -q '/system/bin/linker64' || {
            echo "Unexpected Android ELF interpreter: $binary" >&2
            exit 1
        }
    fi
    while read -r library; do
        case "$library" in
            libc.so|libdl.so|liblog.so|libm.so|libandroid.so|libc++abi.so) continue ;;
        esac
        case "$library" in
            *.so) ;;
            *) echo "JNI-incompatible versioned dependency remains: $library ($binary)" >&2; exit 1 ;;
        esac
        test -f "$OUTPUT_DIR/lib/$library" || { echo "Missing packaged dependency: $library ($binary)" >&2; exit 1; }
    done < <("$READELF" -d "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | sort -u)
done
test -n "$(find "$OUTPUT_DIR/share" -type f -print -quit)" || { echo "MariaDB runtime share data is empty" >&2; exit 1; }
for sql_name in mysql_system_tables.sql mysql_performance_tables.sql mysql_system_tables_data.sql fill_help_tables.sql maria_add_gis_sp_bootstrap.sql mysql_sys_schema.sql; do
    test -s "$OUTPUT_DIR/share/$sql_name" || { echo "Missing packaged bootstrap SQL: $sql_name" >&2; exit 1; }
done

touch "$OUTPUT_DIR/.build-complete"
echo "[mariadb] Runtime ready: $OUTPUT_DIR"
