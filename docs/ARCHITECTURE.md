# Bygdok Eternal Architecture

Bygdok Eternal is one monorepo. The existing AzerothCore server tree, modules, patches, scripts, configurations, and build logic remain the authoritative server implementation and stay at the repository root.

## Target Architecture

```text
Android UI (dashboard, Start/Stop, live status + log)
    |
    v
RealmForegroundService (Android foreground service)
    |
    v
Bygdok native runtime (embedded in jniLibs/arm64-v8a, launched via ProcessBuilder)
    ├── authserver
    ├── worldserver
    └── mariadbd (embedded MariaDB server, no external DB dependency)
    |
    v
Persistent realm data
    ├── configs
    ├── databases
    ├── dbc
    ├── maps
    ├── vmaps
    ├── mmaps
    ├── logs
    └── backups
```

The Android application is the management and hosting layer. `mariadb-runtime.yml` first builds and validates an isolated Android MariaDB artifact using `scripts/build-mariadb-runtime.sh`. `server-runtime.yml` consumes that artifact while packaging authserver, worldserver, MariaDB, and their shared libraries. The Android workflow stages the combined artifact into `jniLibs/arm64-v8a/` under the `lib*.so` naming convention required for executable extraction. `RealmForegroundService` launches `libmariadbd.so`, then `libauthserver.so`, then `libworldserver.so`.

## Implementation Status

- Native runtime embedding (jniLibs staging, `RealmForegroundService` process orchestration, config/asset patching, dashboard wiring) is implemented but **not yet validated on a physical device** — it has not been run through CI or the S25 test device.
- The embedded MariaDB server cross-compile is isolated in `scripts/build-mariadb-runtime.sh`. Its versioned patches follow the established Termux Android port where applicable, while retaining MariaDB 10.11.9 until a complete build and device bootstrap are validated.
- MariaDB's generated share files and bootstrap SQL are packaged into the APK and copied under the on-device `basedir`; physical-device startup remains unvalidated.
- Worldserver's client data (maps/vmaps/mmaps/dbc, ~2 GB) is downloaded on first run from the same URL the existing Termux scripts use (`RealmClientData`); it is not bundled in the APK.

No runtime mechanism is assumed until it is demonstrated in the working ARM64 environment.

## Repository Principles

1. This is one monorepo for Bygdok Eternal.
2. The existing AzerothCore server remains the authoritative server implementation.
3. The Android application is the management and hosting layer.
4. The final product has no Termux dependency.
5. The final product has no root requirement.
6. The final product uses no Linux VM, container, or emulation.
7. Server and Android app versions must be reproducible from the same repository commit.
8. Existing known-good server behaviour must be preserved.
9. Runtime decisions must be based on evidence from the working Samsung Galaxy S25 environment.
10. Avoid speculative architecture and unnecessary frameworks.

## Development Workflow

Development uses `main` and feature branches named `feature/<name>`; no develop, staging, or release branches are required.

1. Create a feature branch.
2. Make one narrowly scoped change.
3. Push the branch.
4. GitHub Actions builds the relevant artifacts.
5. Download the artifacts.
6. Test on the Samsung Galaxy S25.
7. Merge after validation.

Example branches are `feature/runtime-build`, `feature/server-launch`, and `feature/log-streaming`. The S25 is currently the integration-test device. CI artifacts must always be reproducible from the repository commit that produced them.

Android-only changes produce `bygdok-eternal-debug`. Server-runtime changes produce `bygdok-runtime-arm64`. Integration changes produce both artifacts from one workflow run.