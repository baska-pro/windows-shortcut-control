# Windows Shortcut Control

<p align="center">
  <strong>Portable productivity launcher & Windows control center</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-7%20SP1%20%7C%2010%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Windows 7 SP1, 10 and 11">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Version-3.2.1-111827?style=flat-square" alt="Version 3.2.1">
  <img src="https://img.shields.io/badge/Portable-Single%20File-16A34A?style=flat-square" alt="Portable">
  <img src="https://img.shields.io/badge/Language-ID%20%7C%20EN-9333EA?style=flat-square" alt="Indonesian and English">
</p>

<p align="center">
  <a href="https://github.com/baska-pro/windows-shortcut-control/releases/latest">
    <img src="https://img.shields.io/github/v/release/baska-pro/windows-shortcut-control?style=for-the-badge&label=Download%20Latest" alt="Download latest release">
  </a>
  <a href="https://github.com/baska-pro/windows-shortcut-control/releases">
    <img src="https://img.shields.io/github/downloads/baska-pro/windows-shortcut-control/total?style=for-the-badge&label=Downloads" alt="Total downloads">
  </a>
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

No installer or external runtime package is required on a normal Windows 10/11 desktop installation. Windows 7 is also supported when the required PowerShell and .NET components are available.

## Compatibility

| Platform | Status | Notes |
|---|---|---|
| Windows 11 | ✅ Supported | Primary modern Windows target |
| Windows 10 | ✅ Supported | Supported |
| Windows 7 SP1 | ✅ Tested | Requires Windows PowerShell 5.1 and compatible .NET/WPF components |
| Windows Server | ⚠️ Not a primary target | Some desktop/WPF features may depend on installed GUI components |

> Windows 7 does not ship with Windows PowerShell 5.1 by default. If required, install **Windows Management Framework 5.1** before running the application.


## Get the App from GitHub

There are three easy ways to get Windows Shortcut Control on your PC.

### Option 1 — Download the Latest Release (Recommended)

This is the simplest method and does **not** require Git.

1. Open the [latest release](https://github.com/baska-pro/windows-shortcut-control/releases/latest).
2. Under **Assets**, download:

```text
Windows_Shortcut_Control.cmd
```

3. Save the file to a permanent folder, for example:

```text
C:\Tools\Windows-Shortcut-Control\
```

4. Double-click `Windows_Shortcut_Control.cmd`.

If Windows blocks the downloaded file, right-click it → **Properties** → enable **Unblock** if that option is shown → **Apply**.

You can also unblock it from PowerShell:

```powershell
Unblock-File -Path "C:\Tools\Windows-Shortcut-Control\Windows_Shortcut_Control.cmd"
```

### Option 2 — Download the Repository as ZIP

No Git installation is required.

1. Open the repository:
   `https://github.com/baska-pro/windows-shortcut-control`
2. Click **Code**.
3. Choose **Download ZIP**.
4. Extract the ZIP.
5. Open the extracted folder.
6. Run:

```text
Windows_Shortcut_Control.cmd
```

This method also downloads the documentation, screenshots, changelog, and other repository files.

### Option 3 — Clone with Git

Use this method if you want to keep a local copy that can easily be updated later.

Open **Command Prompt**, **PowerShell**, or **Windows Terminal** and run:

```bash
git clone https://github.com/baska-pro/windows-shortcut-control.git
cd windows-shortcut-control
```

Then run:

```cmd
Windows_Shortcut_Control.cmd
```

Or from PowerShell:

```powershell
.\Windows_Shortcut_Control.cmd
```

To update an existing clone later:

```bash
git pull
```

> If Git is not installed, use the Release or Download ZIP method instead.

## Installation / First Run

Windows Shortcut Control is a **portable application**, so there is no traditional installer.

Recommended setup:

1. Put `Windows_Shortcut_Control.cmd` in a permanent folder.
2. Run the file.
3. Complete or skip the built-in first-run guide.
4. Add or import your shortcuts.
5. Open **Settings** if you want to:
   - run the app automatically at Windows sign-in;
   - start directly in the System Tray;
   - configure the Close button behavior;
   - enable the global hotkey;
   - choose Indonesian or English;
   - create a backup.

Example recommended location:

```text
C:\Tools\Windows-Shortcut-Control\
```

### Optional Desktop Shortcut

Right-click `Windows_Shortcut_Control.cmd` → **Send to → Desktop (create shortcut)**.

### Optional Windows Startup

Startup can be enabled directly from the application's **Settings** page.

If startup is enabled, keep the `.cmd` file in the same location. Moving or renaming the file afterward can break the saved startup path.


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

## Screenshots

<p align="center">
  <img src="./assets/screenshots/dashboard.JPG" width="92%" alt="Windows Shortcut Control Dashboard">
</p>

<p align="center">
  <sub>Dashboard — pinned shortcuts, favorites, recent items, and quick access.</sub>
</p>

<table>
  <tr>
    <td width="50%" align="center">
      <img src="./assets/screenshots/shortcuts.JPG" width="100%" alt="Shortcut Manager"><br>
      <strong>Shortcut Manager</strong>
    </td>
    <td width="50%" align="center">
      <img src="./assets/screenshots/windows-tools.JPG" width="100%" alt="Windows Tools"><br>
      <strong>Windows Tools</strong>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <img src="./assets/screenshots/settings.JPG" width="100%" alt="Settings"><br>
      <strong>Settings</strong>
    </td>
    <td width="50%" align="center">
      <img src="./assets/screenshots/guide.JPG" width="100%" alt="Built-in Guide"><br>
      <strong>Built-in Guide</strong>
    </td>
  </tr>
</table>

More visual assets are available in [`assets/screenshots/`](./assets/screenshots/).

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

> Availability of individual Windows Tools depends on the Windows version. Some tools or Settings pages available on Windows 10/11 may not exist on Windows 7.

## Requirements

### Windows 10 / 11

- Windows 10 or Windows 11 desktop
- Windows PowerShell 5.1 or newer
- WPF/.NET components included with normal Windows desktop installations

### Windows 7

- Windows 7 SP1
- Windows PowerShell 5.1
- Windows Management Framework 5.1 when PowerShell 5.1 is not already installed
- Compatible .NET Framework/WPF components

Administrator privileges are **not required for normal use**. Some Windows administrative actions or user-created shortcuts may require elevation.

> The `.cmd` launcher starts `powershell.exe` with `ExecutionPolicy Bypass` for the embedded application code. Review the source before running software downloaded from the Internet.

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

The project is actively maintained and has been tested on Windows 7 SP1 as well as modern Windows versions.

## Issues & Feature Requests

Use GitHub Issues for:

- reproducible bugs;
- compatibility problems;
- feature requests;
- UI/UX suggestions.

For Windows 7 compatibility reports, include:

- Windows 7 edition and architecture;
- confirmation that SP1 is installed;
- PowerShell version (`$PSVersionTable.PSVersion`);
- any relevant Self Diagnostics output.

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
