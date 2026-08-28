# Windows Shortcut Control

<p align="center">
  <strong>Portable productivity launcher & Windows control center</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows11&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Version-3.2.1-111827?style=flat-square" alt="Version 3.2.1">
  <img src="https://img.shields.io/badge/Portable-Single%20File-16A34A?style=flat-square" alt="Portable">
  <img src="https://img.shields.io/badge/Language-ID%20%7C%20EN-9333EA?style=flat-square" alt="Indonesian and English">
</p>

<p align="center">
  <a href="./README.id.md">Bahasa Indonesia</a>
  ·
  <a href="./docs/USER_GUIDE.md">User Guide</a>
  ·
  <a href="./CHANGELOG.md">Changelog</a>
  ·
  <a href="./SECURITY.md">Security</a>
</p>

---

## Overview

**Windows Shortcut Control** is a portable Windows launcher and control center built as a single `.cmd` file with embedded PowerShell/WPF code.

It provides one interface for personal shortcuts, common Windows administrative tools, live system information, backup/recovery, startup behavior, System Tray integration, global search, and keyboard-driven navigation.

No installer or external runtime package is required on a standard Windows desktop installation.

## Highlights

- Modern WPF desktop interface
- Portable single-file distribution
- Dashboard with pinned, favorite, and recently used shortcuts
- Shortcut types:
  - Folder
  - File
  - Application
  - URL
  - PowerShell command
- Drag & drop files/folders to create shortcuts
- Grid, list, and compact shortcut views
- Search and filtering
- Global Search
- Command Palette
- Built-in Windows Tools
- Live System Info and resource monitoring
- System Tray support
- Run at Windows sign-in
- Configurable Close button behavior
- Global hotkey
- JSON import/export
- Full configuration backup/restore
- Last Known Good recovery
- Self Diagnostics
- Single-instance activation
- Indonesian and English UI

## Built-in Windows Tools

Windows Shortcut Control includes quick access to commonly used Windows tools such as:

| Category | Tools |
|---|---|
| File & Folder | File Explorer, Downloads, Desktop, Documents, Recycle Bin |
| System | Task Manager, Control Panel, Windows Settings, System Information, Resource Monitor |
| Management | Services, Task Scheduler, Device Manager, Disk Management, Event Viewer, Registry Editor |
| Network | Network Connections |
| Terminal | PowerShell, Command Prompt |
| Data & Recovery | Import/export, full backup/restore, Last Known Good, reset, diagnostics, Registry data |

## Requirements

- Windows 10 or Windows 11 desktop
- Windows PowerShell 5.1 or newer
- WPF/.NET components included with normal Windows desktop installations
- Administrator privileges are **not required for normal use**
- Some Windows administrative actions or user-created shortcuts may require elevation

> The `.cmd` launcher starts `powershell.exe` with `ExecutionPolicy Bypass` for the embedded application code. Review the source before running software downloaded from the Internet.

## Installation

There is no installer.

1. Download `Windows_Shortcut_Control.cmd`.
2. Save it to a permanent folder.
3. Double-click the file.
4. Complete or skip the first-run guide.
5. Optionally enable **Run at Windows sign-in** from Settings.

### Important

If Windows startup is enabled, avoid moving or renaming the `.cmd` file afterward because the startup registration points to its current path.

## Data Storage

Application settings and shortcut data are stored per-user in the Windows Registry:

```text
HKEY_CURRENT_USER\Software\LaviControlCenter
```

The application can also export:

```text
Shortcut backup       → *.json
Full configuration    → *.wsc.json
```

The source does not include telemetry or automatic outbound API requests. URLs and commands are executed only when launched by the user or by a configured shortcut.

See [Privacy](./docs/PRIVACY.md) for details.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl + K` | Open Command Palette |
| `Ctrl + N` | Add shortcut |
| `Ctrl + F` | Focus Global Search |
| `Ctrl + Shift + F` | Open Shortcuts and focus shortcut search |
| `Ctrl + E` | Export shortcuts |
| `Ctrl + I` | Import shortcuts |
| `Ctrl + B` | Full configuration backup |
| `Ctrl + Shift + B` | Restore full configuration |
| `Ctrl + Shift + D` | Self Diagnostics |
| `Ctrl + Shift + A` | About |
| `Ctrl + Shift + T` | Minimize to System Tray |
| `Ctrl + ,` | Settings |
| `Alt + 1` | Dashboard |
| `Alt + 2` | Shortcuts |
| `Alt + 3` | Windows Tools |
| `Alt + 4` | System Info |
| `Alt + 5` | Settings |
| `F1` | User Guide |
| `F5` | Refresh |
| `Ctrl + Alt + Space` | Global hotkey, when enabled |

## Screenshots

The repository includes an `assets/screenshots/` folder prepared for application screenshots.

Recommended files:

```text
assets/screenshots/dashboard.png
assets/screenshots/shortcuts.png
assets/screenshots/windows-tools.png
assets/screenshots/system-info.png
assets/screenshots/settings.png
assets/screenshots/guide.png
```

After adding screenshots, you can embed them here.

## Architecture

The project intentionally remains a single-file portable application:

```text
Windows_Shortcut_Control.cmd
│
├── CMD bootstrap
│   └── launches Windows PowerShell hidden
│
└── Embedded PowerShell
    ├── WPF user interface
    ├── Registry-backed storage
    ├── shortcut engine
    ├── Windows Tools
    ├── System Tray / global hotkey
    ├── background system monitoring
    ├── backup / restore
    └── diagnostics
```

More details: [Architecture](./docs/ARCHITECTURE.md)

## Security Notes

This application can:

- launch applications and files;
- open URLs;
- execute user-defined PowerShell commands;
- start selected items with administrator privileges;
- open Windows administration tools;
- write per-user settings to the Registry;
- register itself in the current user's Windows startup settings when requested.

Only import configuration files from sources you trust.

See [SECURITY.md](./SECURITY.md).

## Project Status

Current public version:

```text
3.2.1
```

The project is actively maintained.

## Issues & Feature Requests

Use GitHub Issues for:

- reproducible bugs;
- compatibility problems;
- feature requests;
- UI/UX suggestions.

Please do not post passwords, tokens, private paths, personal backup files, or other sensitive information in a public issue.

## License

Copyright © 2026 Lathif Baska.

This repository currently uses an **All Rights Reserved** license to match the copyright notice inside the application.

See [LICENSE](./LICENSE).

> If the project is later intended to become permissive open source, the license and the copyright notice inside the application should be changed together.

## Author

**Lathif Baska**

- GitHub: [@baska-pro](https://github.com/baska-pro)
- Location: Indonesia
