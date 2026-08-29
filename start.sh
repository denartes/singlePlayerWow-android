#!/bin/bash
# Fast incremental Guild Mate & Ollama Chat development build for Android/Termux.
# Requires an initial full build via wowsp_cutoff.sh.
# Usage: ./start.sh

set -e

# ── Paths ──────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$HOME/azerothcore-android"
BUILD_DIR="$SOURCE_DIR/build"
SERVER_DIR="$HOME/azeroth-server"
GUILDMATE_SRC="$REPO_DIR/modules/mod-guild-mate"
GUILDMATE_DST="$SOURCE_DIR/modules/mod-guild-mate"
OLLAMA_SRC="$REPO_DIR/modules/mod-ollama-chat"
OLLAMA_DST="$SOURCE_DIR/modules/mod-ollama-chat"
BUILD_LOG="$HOME/guildmate-build.log"
BUILD_JOBS="${BUILD_JOBS:-4}"
BUILD_STAMP="$BUILD_DIR/.guildmate-ollama-modules.sha256"
TMUX_SESSION="azeroth"

# ── Timing ─────────────────────────────────────────────────────────────────────
TOTAL_START=$(date +%s)
elapsed() { echo $(( $(date +%s) - TOTAL_START ))s; }

print_step() { echo ""; echo "▶ $1"; }
ok()         { echo "  ✓ $1"; }
fail()       { echo "  ✗ $1" >&2; }

module_fingerprint() {
    (
        cd "$REPO_DIR"
        find modules/mod-guild-mate modules/mod-ollama-chat -type f \
            \( -name '*.cpp' -o -name '*.h' -o -name 'CMakeLists.txt' -o -name '*.cmake' -o -name 'include.sh' \) \
            -print0 2>/dev/null \
            | sort -z \
            | xargs -0 sha256sum \
            | sha256sum \
            | awk '{print $1}'
    )
}

list_src_files() {
    find "$1" -type f \( -name '*.cpp' -o -name '*.h' \) 2>/dev/null \
        | sed "s|$1/||" | sort
}

# ── MariaDB functions (adapted from wowsp_cutoff.sh) ───────────────────────────
check_mariadb_running() {
    pgrep -f "mariadbd" > /dev/null 2>&1
}

ensure_mariadb_running() {
    if check_mariadb_running; then
        ok "MariaDB already running"
        return 0
    fi

    echo "  Starting MariaDB..."
    mariadbd-safe --datadir="$PREFIX/var/lib/mysql" &

    local i
    for i in {1..30}; do
        if mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
            ok "MariaDB started"
            return 0
        fi
        printf "."
        sleep 1
    done

    echo ""
    fail "MariaDB failed to start within 30 seconds"
    return 1
}

echo "════════════════════════════════════════"
echo "  Guild Mate & Ollama Chat Dev Build"
echo "════════════════════════════════════════"

# ── 1. Validate prerequisites ──────────────────────────────────────────────────
print_step "Validating prerequisites"

if [ ! -d "$GUILDMATE_SRC" ]; then
    fail "Guild Mate source not found: $GUILDMATE_SRC"
    exit 1
fi
ok "Guild Mate source: $GUILDMATE_SRC"

if [ ! -d "$OLLAMA_SRC" ]; then
    fail "Ollama Chat source not found: $OLLAMA_SRC"
    exit 1
fi
ok "Ollama Chat source: $OLLAMA_SRC"

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

CURRENT_BUILD_HASH=$(module_fingerprint)
PREVIOUS_BUILD_HASH=$(cat "$BUILD_STAMP" 2>/dev/null || true)
SKIP_BUILD=false
if [ -n "$CURRENT_BUILD_HASH" ] && [ "$CURRENT_BUILD_HASH" = "$PREVIOUS_BUILD_HASH" ] && [ -x "$SERVER_DIR/bin/worldserver" ]; then
    SKIP_BUILD=true
    ok "No Guild Mate/Ollama build input changes detected"
fi

# ── helpers: tmux pane identification ──────────────────────────────────────────
find_pane_by_process() {
    local session="$1" procname="$2"
    tmux list-panes -t "$session" -F '#{pane_id} #{pane_pid}' 2>/dev/null | while read -r pane_id pane_pid; do
        if pgrep -P "$pane_pid" -x "$procname" >/dev/null 2>&1 || \
           [ "$(ps -p "$pane_pid" -o comm= 2>/dev/null)" = "$procname" ]; then
            echo "$pane_id"
        fi
    done
}

is_worldserver_running() {
    pgrep -x "worldserver" >/dev/null 2>&1
}

if [ "$SKIP_BUILD" != true ]; then
    # ── 2. Stop worldserver (not authserver, not MariaDB) ─────────────────────
    print_step "Stopping worldserver"

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        WS_PANES=$(find_pane_by_process "$TMUX_SESSION" "worldserver")
        if [ -n "$WS_PANES" ]; then
            for pane_id in $WS_PANES; do
                tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
                sleep 0.5
                tmux kill-pane -t "$pane_id" 2>/dev/null || true
                ok "Stopped worldserver pane $pane_id"
            done
        else
            ok "No worldserver pane found in tmux session"
        fi
    fi

    if is_worldserver_running; then
        pkill -x "worldserver" 2>/dev/null || true
        sleep 1
        if is_worldserver_running; then
            pkill -9 -x "worldserver" 2>/dev/null || true
        fi
        ok "Killed stray worldserver process"
    fi

    # ── 3. Snapshot source-file list before sync (for add/remove detection) ───
    BEFORE_FILES=$(list_src_files "$GUILDMATE_DST"; list_src_files "$OLLAMA_DST")

    # ── 3. Sync Guild Mate & Ollama Chat source ───────────────────────────────
    print_step "Syncing local modules → $SOURCE_DIR/modules"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$GUILDMATE_SRC/" "$GUILDMATE_DST/"
        ok "Guild Mate synced"
        rsync -a --delete "$OLLAMA_SRC/" "$OLLAMA_DST/"
        ok "Ollama Chat synced"
    else
        rm -rf "$GUILDMATE_DST"
        cp -r "$GUILDMATE_SRC" "$GUILDMATE_DST"
        ok "Guild Mate copied (rsync not available)"
        rm -rf "$OLLAMA_DST"
        cp -r "$OLLAMA_SRC" "$OLLAMA_DST"
        ok "Ollama Chat copied (rsync not available)"
    fi

    AFTER_FILES=$(list_src_files "$GUILDMATE_DST"; list_src_files "$OLLAMA_DST")

    # ── 4. Detect whether cmake reconfiguration is needed ─────────────────────
    print_step "Checking for CMake reconfiguration need"

    NEEDS_CMAKE=false
    NEEDS_CMAKE_REASON=""

    for trigger_file in \
            "$GUILDMATE_DST/CMakeLists.txt" \
            "$GUILDMATE_DST/include.sh" \
            "$OLLAMA_DST/mod-ollama-chat.cmake" \
            "$OLLAMA_DST/include.sh"; do
        if [ -f "$trigger_file" ] && [ "$trigger_file" -nt "$BUILD_DIR/CMakeCache.txt" ]; then
            NEEDS_CMAKE=true
            NEEDS_CMAKE_REASON="$(basename "$trigger_file") is newer than CMakeCache.txt"
            break
        fi
    done

    if [ "$BEFORE_FILES" != "$AFTER_FILES" ]; then
        NEEDS_CMAKE=true
        NEEDS_CMAKE_REASON="source file set changed (added/removed .cpp or .h)"
    fi

    if [ "$NEEDS_CMAKE" = true ]; then
        echo "  Reason: $NEEDS_CMAKE_REASON"
        echo "  Running cmake configure with original flags..."
        cd "$BUILD_DIR"
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

    # ── 5. Incremental worldserver build ──────────────────────────────────────
    print_step "Building worldserver (incremental)"
    echo "  Log: $BUILD_LOG"
    echo "  Jobs: $BUILD_JOBS (use BUILD_JOBS=1 ./start.sh on low memory)"

    COMPILE_START=$(date +%s)
    cd "$BUILD_DIR"

    set +e
    make -j"$BUILD_JOBS" worldserver 2>&1 | tee "$BUILD_LOG"
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

    # ── 6. Install worldserver binary ─────────────────────────────────────────
    print_step "Installing worldserver binary"

    BUILT_BINARY="$BUILD_DIR/src/server/apps/worldserver/worldserver"
    if [ ! -f "$BUILT_BINARY" ]; then
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

    # ── 6b. Update .conf.dist (safe — never touches the live .conf) ───────────
    CONF_DIST_SRC="$GUILDMATE_SRC/conf/mod_guild_mate.conf.dist"
    CONF_DIST_DST="$SERVER_DIR/etc/modules/mod_guild_mate.conf.dist"
    if [ -f "$CONF_DIST_SRC" ]; then
        mkdir -p "$SERVER_DIR/etc/modules"
        cp "$CONF_DIST_SRC" "$CONF_DIST_DST"
        ok "Updated: $CONF_DIST_DST (live .conf untouched)"
    fi

    OLLAMA_CONF_DIST_SRC="$OLLAMA_SRC/conf/mod_ollama_chat.conf.dist"
    OLLAMA_CONF_DIST_DST="$SERVER_DIR/etc/modules/mod_ollama_chat.conf.dist"
    if [ -f "$OLLAMA_CONF_DIST_SRC" ]; then
        mkdir -p "$SERVER_DIR/etc/modules"
        cp "$OLLAMA_CONF_DIST_SRC" "$OLLAMA_CONF_DIST_DST"
        ok "Updated: $OLLAMA_CONF_DIST_DST (live .conf untouched)"
    fi

    echo "$CURRENT_BUILD_HASH" > "$BUILD_STAMP"
else
    print_step "Skipping build"
    ok "Module build inputs unchanged; using existing worldserver binary"
fi

# ── 7. Ensure MariaDB is running ──────────────────────────────────────────────
print_step "Ensuring MariaDB is running"

if ! ensure_mariadb_running; then
    fail "Cannot start AzerothCore servers without MariaDB"
    exit 1
fi

# ── 8. Restart worldserver ────────────────────────────────────────────────────
print_step "Starting AzerothCore servers"

if is_worldserver_running; then
    pkill -9 -x "worldserver" 2>/dev/null || true
    sleep 0.5
fi

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    ok "Killing existing tmux session"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi

echo ""
echo "════════════════════════════════════════"
echo "  Guild Mate & Ollama Chat Dev Build"
echo "  Complete"
echo "  Total elapsed: $(elapsed)"
echo "════════════════════════════════════════"
echo ""
echo "Launching AzerothCore servers in tmux..."

cd "$SERVER_DIR"
tmux new-session -d -c "$SERVER_DIR" -s "$TMUX_SESSION" './bin/authserver' \; \
     split-window -h -c "$SERVER_DIR" './bin/worldserver' \; \
     attach
