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

These findings must not be treated as an Android runtime implementation. No binaries or libraries are bundled by this repository scaffold.

## CI Dependency Bootstrap

The server-runtime workflow builds Android ARM64 dependencies from pinned official source releases into a job-owned prefix at `${RUNNER_TEMP}/bygdok-android-deps`. The MariaDB client prefix is `${RUNNER_TEMP}/bygdok-android-deps/mysql`; staged runtime libraries are under `${RUNNER_TEMP}/bygdok-android-deps/lib`. These paths are created by CI and are not developer or Termux paths.

The bootstrap pins zlib 1.3.1, OpenSSL 3.0.15, xz 5.6.3, ncurses 6.5, readline 8.2, bzip2 1.0.8, Boost 1.85.0, and MariaDB Connector/C 3.3.8. It also stages the matching NDK r29 `libc++_shared.so` and `libunwind.so` where required. The cache key includes these build inputs through the bootstrap script hash, Android API 30, ABI `arm64-v8a`, and NDK `29.0.14206865`.