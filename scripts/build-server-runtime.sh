#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="${CORE_DIR:-${RUNNER_TEMP:-/tmp}/azerothcore-android}"
BUILD_DIR="${BUILD_DIR:-${RUNNER_TEMP:-/tmp}/azerothcore-build}"
INSTALL_DIR="${INSTALL_DIR:-${REPO_DIR}/runtime/build/server-install}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}/runtime/build/bygdok-runtime-arm64}"
CORE_COMMIT="abc884520173084d5cd37b72b57b3822230dcb32"
CORE_REPOSITORY="https://github.com/duall/azerothcore-android.git"
ANDROID_API="${ANDROID_API:-30}"

: "${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT must point to Android NDK r29}"
: "${ANDROID_MYSQL_ROOT:?ANDROID_MYSQL_ROOT must point to an Android ARM64 MariaDB/MySQL client toolchain}"
: "${ANDROID_RUNTIME_LIB_DIR:?ANDROID_RUNTIME_LIB_DIR must contain Android ARM64 runtime libraries}"

TOOLCHAIN_DIR="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64"
ANDROID_CLANG="${TOOLCHAIN_DIR}/bin/aarch64-linux-android${ANDROID_API}-clang"
ANDROID_CLANGXX="${TOOLCHAIN_DIR}/bin/aarch64-linux-android${ANDROID_API}-clang++"
ANDROID_READELF="${TOOLCHAIN_DIR}/bin/llvm-readelf"

for required in "$ANDROID_CLANG" "$ANDROID_CLANGXX" "$ANDROID_READELF" "$ANDROID_MYSQL_ROOT/bin/mysql_config"; do
    test -x "$required" || { echo "Missing required Android build tool: $required" >&2; exit 1; }
done

rm -rf "$CORE_DIR" "$BUILD_DIR" "$INSTALL_DIR" "$OUTPUT_DIR"
git clone "$CORE_REPOSITORY" "$CORE_DIR"
git -C "$CORE_DIR" fetch --depth=1 origin "$CORE_COMMIT"
git -C "$CORE_DIR" checkout --detach "$CORE_COMMIT"

# Match the Boost compatibility patch used by wowsp_cutoff.sh.
BOOST_CMAKE="$CORE_DIR/deps/boost/CMakeLists.txt"
sed -i -E 's/ system / /g; s/ system$//g; s/^system //g' "$BOOST_CMAKE"
grep -q 'CMP0167' "$BOOST_CMAKE" || sed -i '1i cmake_policy(SET CMP0167 OLD)' "$BOOST_CMAKE"

# Reuse the locked module list from the known-good Termux build script.
mkdir -p "$CORE_DIR/modules"
sed -n '/^MODULES=(/,/^)/p' "$REPO_DIR/wowsp_cutoff.sh" \
    | grep '"https://' \
    | sed -E 's/.*"(https:[^"]+) ([0-9a-f]+)".*/\1|\2/' \
    | while IFS='|' read -r repository commit; do
        name="$(basename "$repository" .git)"
        git clone "$repository" "$CORE_DIR/modules/$name"
        git -C "$CORE_DIR/modules/$name" checkout --detach "$commit"
      done

# Build the modules maintained in this monorepo from the same commit.
for module in "$REPO_DIR"/modules/*; do
    test -d "$module" || continue
    rm -rf "$CORE_DIR/modules/$(basename "$module")"
    cp -R "$module" "$CORE_DIR/modules/"
done

export PATH="$ANDROID_MYSQL_ROOT/bin:$PATH"
export MYSQL_HOME="$ANDROID_MYSQL_ROOT"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"
cmake -S "$CORE_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${ANDROID_ABI:-arm64-v8a}" \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_C_COMPILER="$ANDROID_CLANG" \
    -DCMAKE_CXX_COMPILER="$ANDROID_CLANGXX" \
    -DWITH_WARNINGS=1 -DTOOLS_BUILD=none -DSCRIPTS=static \
    -DCMAKE_CXX_FLAGS="-D__ANDROID__ -DANDROID -Wno-deprecated-literal-operator" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition -lunwind"
cmake --build "$BUILD_DIR" --parallel
cmake --install "$BUILD_DIR"

mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib"
cp "$INSTALL_DIR/bin/authserver" "$OUTPUT_DIR/bin/"
cp "$INSTALL_DIR/bin/worldserver" "$OUTPUT_DIR/bin/"

for binary in "$OUTPUT_DIR/bin/authserver" "$OUTPUT_DIR/bin/worldserver"; do
    while read -r library; do
        case "$library" in
            libc.so|libdl.so|liblog.so|libm.so|libandroid.so|libc++abi.so) continue ;;
        esac
        found="$(find "$ANDROID_RUNTIME_LIB_DIR" "$TOOLCHAIN_DIR/sysroot/usr/lib/aarch64-linux-android" -name "$library" -type f -print -quit)"
        test -n "$found" || { echo "Required runtime library not found: $library" >&2; exit 1; }
        cp -n "$found" "$OUTPUT_DIR/lib/"
    done < <("$ANDROID_READELF" -d "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | sort -u)
done

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$OUTPUT_DIR/manifest.json" "$timestamp" "$ANDROID_API" "$REPO_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys

output = pathlib.Path(sys.argv[1])
manifest = {
    "git_commit": subprocess.check_output(["git", "-C", sys.argv[4], "rev-parse", "HEAD"], text=True).strip(),
    "build_timestamp": sys.argv[2],
    "target_architecture": "arm64-v8a",
    "android_api": int(sys.argv[3]),
    "binaries": sorted(path.name for path in (output.parent / "bin").iterdir()),
    "shared_libraries": sorted(path.name for path in (output.parent / "lib").iterdir()),
}
output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY