# Architecture

Windows Shortcut Control is intentionally distributed as a single portable
Windows file.

## Bootstrap Layer

The beginning of `Windows_Shortcut_Control.cmd` is a small CMD launcher.

It:

1. stores its own path in an environment variable;
2. detects the `--startup` argument;
3. starts Windows PowerShell hidden;
4. reads its own file;
5. locates the embedded PowerShell marker;
6. executes the embedded application code.

## Application Layer

The embedded PowerShell code provides:

```text
PowerShell
├── WPF interface
├── shortcut model
├── Registry persistence
├── localization
├── Windows Tools catalog
├── search / Command Palette
├── System Tray
├── global hotkey
├── Windows startup registration
├── background system information
├── live monitor
├── import / export
├── backup / recovery
└── self diagnostics
```

## Persistence

Primary per-user Registry location:

```text
HKCU:\Software\LaviControlCenter
```

The application stores shortcut and settings JSON values in this location.

Windows startup registration uses:

```text
HKCU:\Software\Microsoft\Windows\CurrentVersion\Run
```

when the user enables startup.

## Single Instance

The application uses a named local mutex and activation event. A second launch
signals the existing instance instead of opening another normal instance.

## Background Work

System information and monitoring use PowerShell background runspace mechanisms
so expensive system queries do not need to block the main WPF UI.

## Network Behavior

The application has no built-in telemetry or automatic remote API client.

Network-related actions are limited to:

- opening a user-configured URL;
- displaying local network activity;
- opening Windows network management tools.

## Design Goal

The architecture prioritizes:

- portability;
- no installer;
- minimal external dependencies;
- per-user persistence;
- easy backup and recovery.
