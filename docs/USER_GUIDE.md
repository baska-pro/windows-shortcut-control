# User Guide

## 1. Start the Application

Run:

```text
Windows_Shortcut_Control.cmd
```

The first instance opens the application. If an instance is already running,
launching the file again signals the existing instance and brings it back.

## 2. Dashboard

The Dashboard is designed for frequently used items:

- **Pinned** — shortcuts intentionally pinned to the Dashboard.
- **Favorites** — marked favorite shortcuts.
- **Recent** — recently opened shortcuts.

Right-click a shortcut to access additional actions.

## 3. Shortcuts

Supported shortcut types:

- Folder
- File
- App
- URL
- PowerShell

Typical actions include:

- Open
- Open Location / Parent Folder
- Copy Target
- Pin / Unpin
- Add / Remove Favorite
- Open Terminal Here
- Run as Administrator
- Duplicate
- Move Up / Down
- Edit
- Delete

You can also drag files or folders from File Explorer into the application.

## 4. Windows Tools

Built-in categories:

- File & Folder
- System
- Management
- Network
- Terminal
- Data & Recovery

Use the search box to quickly find tools such as Task Manager, Registry Editor,
Device Manager, backup, or diagnostics.

## 5. System Info

System Info provides information such as:

- computer name;
- current user;
- Windows version;
- CPU;
- RAM;
- uptime;
- disk usage.

The live monitor displays CPU, RAM, download, and upload activity.

Monitoring is intended to run while the System Info page is active.

## 6. Settings

Settings include:

- Run at Windows sign-in
- Start in System Tray
- Close button behavior
- Global hotkey
- Language
- Backup / Restore
- Self Diagnostics
- User Guide

## 7. Backup

### Shortcut Export

Produces a JSON file containing shortcut data including:

- target;
- type;
- category;
- pin/favorite state;
- open count;
- recent information.

### Full Configuration Backup

Produces:

```text
*.wsc.json
```

It contains shortcuts and application settings.

Review exported files before sharing because user-defined targets or commands may
contain personal or machine-specific information.

## 8. Recovery

Available recovery tools include:

- Last Known Good
- Registry backups created before selected restore/reset operations
- Full configuration restore
- Reset shortcuts
- Self Diagnostics

## 9. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Ctrl + K | Command Palette |
| Ctrl + N | New shortcut |
| Ctrl + F | Global Search |
| Ctrl + Shift + F | Shortcut search |
| Ctrl + E | Export shortcuts |
| Ctrl + I | Import shortcuts |
| Ctrl + B | Backup full config |
| Ctrl + Shift + B | Restore full config |
| Ctrl + Shift + D | Diagnostics |
| Ctrl + Shift + A | About |
| Ctrl + Shift + T | Send to System Tray |
| Ctrl + , | Settings |
| Alt + 1..5 | Main navigation |
| F1 | User Guide |
| F5 | Refresh |
| Ctrl + Alt + Space | Global hotkey when enabled |

## 10. Troubleshooting

### App does not open

- Confirm you are using Windows desktop.
- Confirm Windows PowerShell is available.
- Try launching from a normal local folder.
- Run Self Diagnostics when the app can open.

### Startup no longer works

If you moved or renamed the `.cmd` after enabling startup:

1. Open the application manually.
2. Disable **Run at Windows sign-in**.
3. Save Settings.
4. Re-enable it from the new location.

### Imported configuration causes problems

Restore a known-good backup or use Last Known Good / reset options.

Only import files from trusted sources.
