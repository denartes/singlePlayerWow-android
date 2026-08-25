#!/bin/bash
# Fast incremental Guild Mate development build for Android/Termux.
# Requires an initial full build via wowsp_cutoff.sh.
# Usage: bash guildmate-dev-build.sh

set -e

# ── Paths ──────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$HOME/azerothcore-android"
BUILD_DIR="$SOURCE_DIR/build"
SERVER_DIR="$HOME/azeroth-server"
GUILDMATE_SRC="$REPO_DIR/modules/mod-guild-mate"
GUILDMATE_DST="$SOURCE_DIR/modules/mod-guild-mate"
BUILD_LOG="$HOME/guildmate-build.log"
TMUX_SESSION="azeroth"
TMUX_WINDOW="$TMUX_SESSION:0"

# ── Timing ─────────────────────────────────────────────────────────────────────
TOTAL_START=$(date +%s)
elapsed() { echo $(( $(date +%s) - TOTAL_START ))s; }

print_step() { echo ""; echo "▶ $1"; }
ok()         { echo "  ✓ $1"; }
fail()       { echo "  ✗ $1" >&2; }

echo "════════════════════════════════════════"
echo "  Guild Mate Dev Build"
echo "════════════════════════════════════════"

# ── 1. Validate prerequisites ──────────────────────────────────────────────────
print_step "Validating prerequisites"

if [ ! -d "$GUILDMATE_SRC" ]; then
    fail "Guild Mate source not found: $GUILDMATE_SRC"
    exit 1
fi
ok "Guild Mate source: $GUILDMATE_SRC"

if [ ! -d "$SOURCE_DIR" ]; then
    fail "AzerothCore source not found: $SOURCE_DIR"
    fail "Run wowsp_cutoff.sh first for the initial full build."
    exit 1
fi
ok "Source dir: $SOURCE_DIR"

if [ ! -d "$BUILD_DIR" ]; then
    fail "Build directory not found: $BUILD_DIR"
    fail "Run wowsp_cutoff.sh first for the initial full build."
    exit 1
fi
ok "Build dir: $BUILD_DIR"

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    fail "No CMakeCache.txt in $BUILD_DIR — initial cmake configure has not run."
    fail "Run wowsp_cutoff.sh first."
    exit 1
fi
ok "CMakeCache.txt present"

if [ ! -d "$SERVER_DIR" ]; then
    fail "Server install dir not found: $SERVER_DIR"
    fail "Run wowsp_cutoff.sh first."
    exit 1
fi
ok "Server dir: $SERVER_DIR"

# ── helpers: locate panes in the azeroth session ─────────────────────────────
# Returns the index of the first pane whose command matches a pattern.
# Usage: find_pane_index <window> <grep-pattern>
find_pane_index() {
    local window="$1" pattern="$2"
    tmux list-panes -t "$window" \
        -F '#{pane_index} #{pane_current_command}' 2>/dev/null \
        | awk -v p="$pattern" '$2 ~ p {print $1; exit}'
}

# ── 2. Stop worldserver (not authserver, not MariaDB) ─────────────────────────
print_step "Stopping worldserver"

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    WS_PANE=$(find_pane_index "$TMUX_WINDOW" "worldserver")

    if [ -n "$WS_PANE" ]; then
        # Kill the pane directly — worldserver runs without a shell behind it,
        # so C-c would just close the pane anyway; kill-pane is deterministic.
        tmux kill-pane -t "${TMUX_WINDOW}.${WS_PANE}"
        ok "Killed worldserver tmux pane ${TMUX_WINDOW}.${WS_PANE}"
    else
        ok "No worldserver pane found in session '$TMUX_SESSION' (already gone)"
    fi

    # Belt-and-suspenders: kill any stray worldserver process not in tmux
    pkill -f "bin/worldserver" 2>/dev/null || true
else
    pkill -f "bin/worldserver" 2>/dev/null || true
    ok "No tmux session found; killed any stray worldserver process"
fi

# ── 3. Snapshot source-file list before sync (for add/remove detection) ───────
# CMake may use GLOB_RECURSE in the module's CMakeLists.txt, which means CMake
# itself won't detect added/removed source files without re-running configure.
# Capture the sorted file list before and after sync to catch this case.
list_src_files() {
    find "$1" -type f \( -name '*.cpp' -o -name '*.h' \) 2>/dev/null \
        | sed "s|$1/||" | sort
}

BEFORE_FILES=$(list_src_files "$GUILDMATE_DST")

# ── 3. Sync Guild Mate source ──────────────────────────────────────────────────
print_step "Syncing Guild Mate source → $GUILDMATE_DST"

if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$GUILDMATE_SRC/" "$GUILDMATE_DST/"
    ok "rsync complete"
else
    rm -rf "$GUILDMATE_DST"
    cp -r "$GUILDMATE_SRC" "$GUILDMATE_DST"
    ok "cp complete (rsync not available)"
fi

AFTER_FILES=$(list_src_files "$GUILDMATE_DST")

# ── 4. Detect whether cmake reconfiguration is needed ─────────────────────────
print_step "Checking for CMake reconfiguration need"

NEEDS_CMAKE=false
NEEDS_CMAKE_REASON=""

# Trigger 1: CMakeLists.txt or include.sh changed (build rules or flags changed)
for trigger_file in \
        "$GUILDMATE_DST/CMakeLists.txt" \
        "$GUILDMATE_DST/include.sh"; do
    if [ -f "$trigger_file" ] && [ "$trigger_file" -nt "$BUILD_DIR/CMakeCache.txt" ]; then
        NEEDS_CMAKE=true
        NEEDS_CMAKE_REASON="$(basename "$trigger_file") is newer than CMakeCache.txt"
    fi
done

# Trigger 2: source-file set changed (file added or removed).
# Required because GLOB_RECURSE in CMakeLists.txt won't re-evaluate without reconfigure.
if [ "$BEFORE_FILES" != "$AFTER_FILES" ]; then
    NEEDS_CMAKE=true
    NEEDS_CMAKE_REASON="source file set changed (added/removed .cpp or .h)"
fi

if [ "$NEEDS_CMAKE" = true ]; then
    echo "  Reason: $NEEDS_CMAKE_REASON"
    echo "  Running cmake configure with original flags..."
    cd "$BUILD_DIR"
    # Exact flags from wowsp_cutoff.sh
    cmake "$SOURCE_DIR" \
        -DCMAKE_INSTALL_PREFIX="$SERVER_DIR" \
        -DCMAKE_C_COMPILER="$PREFIX/bin/clang" \
        -DCMAKE_CXX_COMPILER="$PREFIX/bin/clang++" \
        -DWITH_WARNINGS=1 -DTOOLS=0 -DSCRIPTS=static \
        -DCMAKE_CXX_FLAGS="-D__ANDROID__ -DANDROID -Wno-deprecated-literal-operator" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition -lunwind"
    ok "CMake reconfigure: yes"
else
    ok "CMake reconfigure: no (existing source files changed only)"
fi

# ── 5. Incremental worldserver build ──────────────────────────────────────────
print_step "Building worldserver (incremental)"
echo "  Log: $BUILD_LOG"

COMPILE_START=$(date +%s)
cd "$BUILD_DIR"

set +e
make -j"$(nproc)" worldserver 2>&1 | tee "$BUILD_LOG"
MAKE_EXIT=${PIPESTATUS[0]}
set -e

COMPILE_ELAPSED=$(( $(date +%s) - COMPILE_START ))

if [ "$MAKE_EXIT" -ne 0 ]; then
    echo ""
    fail "Compilation failed (${COMPILE_ELAPSED}s). Build tree preserved."
    echo ""
    echo "  Full log: $BUILD_LOG"
    echo ""
    echo "  To see the first real error without parallel noise:"
    echo "    cd $BUILD_DIR"
    echo "    make -j1 worldserver 2>&1 | tee ~/guildmate-build-error.log"
    exit 1
fi

ok "Compiled in ${COMPILE_ELAPSED}s"

# ── 6. Install worldserver binary ─────────────────────────────────────────────
print_step "Installing worldserver binary"

# Copy only the worldserver binary — avoids touching configs, data, or databases.
BUILT_BINARY="$BUILD_DIR/src/server/apps/worldserver/worldserver"
if [ ! -f "$BUILT_BINARY" ]; then
    # Fallback: search under build/bin
    BUILT_BINARY=$(find "$BUILD_DIR" -name "worldserver" -type f | grep -v "\.dir" | head -1)
fi

if [ -z "$BUILT_BINARY" ] || [ ! -f "$BUILT_BINARY" ]; then
    fail "Could not locate built worldserver binary under $BUILD_DIR"
    exit 1
fi

mkdir -p "$SERVER_DIR/bin"
cp "$BUILT_BINARY" "$SERVER_DIR/bin/worldserver"
chmod +x "$SERVER_DIR/bin/worldserver"
ok "Installed: $SERVER_DIR/bin/worldserver"

# ── 6b. Update .conf.dist (safe — never touches the live .conf) ───────────────
CONF_DIST_SRC="$GUILDMATE_SRC/conf/mod_guild_mate.conf.dist"
CONF_DIST_DST="$SERVER_DIR/etc/modules/mod_guild_mate.conf.dist"
if [ -f "$CONF_DIST_SRC" ]; then
    mkdir -p "$SERVER_DIR/etc/modules"
    cp "$CONF_DIST_SRC" "$CONF_DIST_DST"
    ok "Updated: $CONF_DIST_DST (live .conf untouched)"
fi

# ── 7. Restart worldserver ────────────────────────────────────────────────────
print_step "Restarting worldserver"

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # The worldserver pane (if any) was already killed above.
    # Create a fresh pane alongside whatever remains (authserver).
    # -h splits horizontally; -c sets the working directory.
    tmux split-window -h -t "$TMUX_WINDOW" \
        -c "$SERVER_DIR" \
        './bin/worldserver'
    ok "worldserver launched in new tmux pane (${TMUX_WINDOW})"
else
    echo "  tmux session '$TMUX_SESSION' not found."
    echo "  To start the full session:"
    echo "    cd $SERVER_DIR"
    echo "    tmux new-session -d -s $TMUX_SESSION './bin/authserver' \\"
    echo "         \\; split-window -h -c '$SERVER_DIR' './bin/worldserver' \\"
    echo "         \\; attach"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Guild Mate Dev Build — Complete"
echo "  Total elapsed: $(elapsed)"
echo "════════════════════════════════════════"
