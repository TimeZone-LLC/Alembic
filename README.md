# Alembic

Alembic is an Arcane Flutter desktop app for managing GitHub checkouts, local archives, and scheduled Archive Master mirrors on macOS and Windows.

Connect one or more GitHub accounts, clone repositories, or import existing GitHub checkouts in place. Search and filter the workspace, open repositories in configured editors and Git clients, and archive or restore local copies. Per-repository settings control authentication, tools, and the subdirectory to open.

Settings include storage locations, archive schedules, commit signing, startup and tray behavior, appearance, application updates, and diagnostics. The interface follows the system appearance or a chosen light/dark theme and adapts to compact desktop windows.

## Development

Use the Flutter SDK compatible with `pubspec.yaml`, Git, and the native platform toolchain. macOS requires macOS 12 or newer and Xcode/CocoaPods. Windows requires the Visual Studio desktop C++ workload.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

Use `flutter run -d windows` on Windows. Build and distribution entrypoints are in `scripts/release/`; they are separate from local tests. A signed macOS distribution requires the configured signing credentials.

## Data and recovery

Configuration and account storage live in the `Alembic` directory under the user's Documents folder. Imported GitHub checkouts retain their original locations. Other Git hosts may be discovered during import but are explicitly marked unsupported.

Only one Alembic process can own its data directory. Account migration verifies the replacement and retains the original encrypted backup; unreadable storage produces a startup error rather than being erased. Keep the data directory and its key together when backing up or investigating a startup failure.

## Verification

Tests use temporary storage and local fixtures. Coverage includes archive transactions, import paths, authentication choices, launch failures, updater/restart scripts, keyboard controls, and desktop layouts in both themes. Windows-specific script tests require Windows. Real account access, OS startup registration, tray interaction, and signed installation still require native acceptance testing.

Generated plans, screenshots, reports, and build output are ignored by Git.
