# Runtime Facts

The following facts have been established from the working Samsung Galaxy S25 deployment. They are observations and constraints, not an implementation plan.

1. `authserver` and `worldserver` are Android ARM64 ELF shared objects.
2. Both target Android 30.
3. Both are built with Android NDK r29.
4. Both use `/system/bin/linker64`.
5. Both currently use Termux-specific RUNPATH entries.
6. Their dependency names themselves are portable and include:
   - `libmariadb`
   - Boost libraries
   - OpenSSL
   - zlib
   - `libc++_shared`
   - bzip2
   - lzma
7. `worldserver` additionally requires readline and ncurses.
8. A copied `authserver` has been proven to execute successfully from a separate runtime directory using `LD_LIBRARY_PATH=<runtime>/lib`.
9. The isolated `authserver` has been proven to perform a successful dry run using the existing config and database.
10. The current working theory is that AzerothCore does not need to be rewritten for Android; the main problem is packaging and launching the existing Android-native runtime inside the app sandbox.

These findings establish the constraints that the current implementation (`RealmForegroundService`, `embedNativeRuntime` Gradle task) is built against. The app now bundles `authserver`, `worldserver`, and an embedded `mariadbd` as `jniLibs/arm64-v8a/lib*.so`, but this bundling has not yet been validated on a physical device.

## CI Dependency Bootstrap

The server-runtime workflow builds Android ARM64 dependencies from pinned official source releases into a job-owned prefix at `${{ github.workspace }}/.ci/bygdok-android-deps`. The MariaDB client prefix is `${{ github.workspace }}/.ci/bygdok-android-deps/mysql`; staged runtime libraries are under `${{ github.workspace }}/.ci/bygdok-android-deps/lib`. These paths are created by CI and are not developer or Termux paths.

The bootstrap pins zlib 1.3.1, OpenSSL 3.0.15, xz 5.6.3, ncurses 6.5, readline 8.2, bzip2 1.0.8, Boost 1.85.0, MariaDB Connector/C 3.3.8, and (experimental, unvalidated in CI as of this writing) MariaDB Server 10.11.9, cross-compiled into `mariadbd` for on-device embedding so the final product requires no external/Termux-hosted database. It also stages the matching NDK r29 `libc++_shared.so` and `libunwind.so` where required. The cache key includes these build inputs through the bootstrap script hash, Android API 30, ABI `arm64-v8a`, and NDK `29.0.14206865`.

## Embedded Runtime Orchestration (implemented, not device-validated)

- `android.yml` depends on `server-runtime.yml`, downloads the `bygdok-runtime-arm64` artifact, and the `embedNativeRuntime` Gradle task in `android/app/build.gradle.kts` copies/renames `bin/{authserver,worldserver,mariadbd,mariadb_client}` and all `lib/*.so` files into `app/src/main/jniLibs/arm64-v8a/`, plus copies the packaged SQL update tree into `assets/sql`. This task is a no-op (dashboard-only APK) if the runtime directory is absent, preserving the previously-validated local build path.
- `RealmForegroundService` (`android/app/src/main/java/com/denartes/bygdoketernal/realm/`) launches `libmariadbd.so --initialize-insecure` on first run, starts `mariadbd` bound to `127.0.0.1:3306`, waits for the TCP port, bootstraps the `acore` user and `acore_auth`/`acore_world`/`acore_characters`/`acore_playerbots` databases via `libmariadbclient.so` (if present), then launches `libauthserver.so` and `libworldserver.so` with `LD_LIBRARY_PATH` set to the app's `nativeLibraryDir`.
- Config files are copied from assets (sourced directly from the repository's `configs/` directory, added as an extra Gradle asset source dir) into app-private storage, patching only `LogsDir`, `SourceDirectory`, and (worldserver) `DataDir` to on-device absolute paths. The default `LoginDatabaseInfo`/`WorldDatabaseInfo`/`CharacterDatabaseInfo` connection strings (`127.0.0.1;3306;acore;acore;<db>`) are left untouched since they already match the embedded `mariadbd`.
- Worldserver's client data (maps/vmaps/mmaps/dbc, ~2 GB) is downloaded on first run from `https://github.com/wowgaming/client-data/releases/download/v16/data.zip` (the same URL the existing Termux scripts use) and is not bundled in the APK.
- Highest-risk, least-proven pieces: the `mariadbd` cross-compile itself, and whether `mariadbd` can locate its error-message/locale files (`share/errmsg.sys`) under the synthetic `basedir` created on-device. Both are expected to require iterative CI/device-log-driven fixes, matching the pattern used for every other native component in this project so far.