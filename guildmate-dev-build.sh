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
WORLDSERVER_PANE="$TMUX_SESSION:0.1"

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

# ── 2. Stop worldserver (not authserver, not MariaDB) ─────────────────────────
print_step "Stopping worldserver"

WORLDSERVER_STOPPED=false
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # Send Ctrl-C to the worldserver pane and wait briefly
    tmux send-keys -t "$WORLDSERVER_PANE" C-c 2>/dev/null || true
    sleep 2
    # Fallback: kill by process name if still running
    pkill -f "bin/worldserver" 2>/dev/null || true
    sleep 1
    WORLDSERVER_STOPPED=true
    ok "Sent stop signal to worldserver pane ($WORLDSERVER_PANE)"
else
    # No tmux session — just kill any stray worldserver process
    pkill -f "bin/worldserver" 2>/dev/null || true
    ok "No tmux session found; killed any stray worldserver process"
fi

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

# ── 4. Detect whether cmake reconfiguration is needed ─────────────────────────
print_step "Checking for CMake reconfiguration need"

NEEDS_CMAKE=false

# CMake reconfiguration is needed if CMakeLists.txt or include.sh
# in the guild-mate module is newer than the existing CMakeCache.
for trigger_file in \
        "$GUILDMATE_DST/CMakeLists.txt" \
        "$GUILDMATE_DST/include.sh"; do
    if [ -f "$trigger_file" ] && [ "$trigger_file" -nt "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "  CMake trigger: $(basename "$trigger_file") is newer than CMakeCache.txt"
        NEEDS_CMAKE=true
    fi
done

if [ "$NEEDS_CMAKE" = true ]; then
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
    ok "CMake reconfigure: no (source file changes only)"
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

# ── 7. Restart worldserver ────────────────────────────────────────────────────
print_step "Restarting worldserver"

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # Clear the pane and relaunch worldserver from the server directory
    tmux send-keys -t "$WORLDSERVER_PANE" "" Enter 2>/dev/null || true
    sleep 1
    tmux send-keys -t "$WORLDSERVER_PANE" "cd $SERVER_DIR && ./bin/worldserver" Enter
    ok "worldserver restarted in tmux pane $WORLDSERVER_PANE"
else
    echo "  tmux session '$TMUX_SESSION' not found."
    echo "  Start the full session with:"
    echo "    cd $SERVER_DIR"
    echo "    tmux new-session -d -s $TMUX_SESSION './bin/authserver' \\"
    echo "         \\; split-window -h './bin/worldserver' \\"
    echo "         \\; attach"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Guild Mate Dev Build — Complete"
echo "  Total elapsed: $(elapsed)"
echo "════════════════════════════════════════"
