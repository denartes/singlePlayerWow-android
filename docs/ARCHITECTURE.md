# Bygdok Eternal Architecture

Bygdok Eternal is one monorepo. The existing AzerothCore server tree, modules, patches, scripts, configurations, and build logic remain the authoritative server implementation and stay at the repository root.

## Target Architecture

```text
Android UI
    |
    v
Android foreground server service
    |
    v
Bygdok native runtime
    ├── authserver
    ├── worldserver
    └── database runtime
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

The Android application is the future management and hosting layer. The `runtime/` directory is reserved for packaging the existing Android-native server runtime; it does not launch, download, or contain that runtime yet.

## Unresolved Work

- Native runtime integration into the Android application is unresolved.
- The database runtime and its Android packaging are unresolved.
- The foreground server service is a future design boundary, not an implementation in this scaffold.

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