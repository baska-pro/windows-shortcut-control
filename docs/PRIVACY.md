# Privacy

Windows Shortcut Control is designed as a local Windows utility.

## Data Stored Locally

The application stores per-user configuration in:

```text
HKEY_CURRENT_USER\Software\LaviControlCenter
```

Stored data can include:

- shortcut names;
- local paths;
- URLs;
- PowerShell commands;
- categories;
- favorite/pinned state;
- usage counters;
- recent-open timestamps;
- application settings.

## Exported Files

The user may explicitly export:

- shortcut JSON files;
- full configuration `.wsc.json` files.

These files can contain private paths, URLs, commands, and other user-entered data.

Do not publish backup files without reviewing them.

## Telemetry

The current source does not include:

- analytics;
- telemetry upload;
- automatic API reporting;
- cloud synchronization.

## User-Initiated Network Actions

The application can open URLs that the user has configured as shortcuts.
This uses the normal Windows mechanism for opening the target and is initiated
by the user.

## System Information

System Info reads local operating system and hardware information for display in
the application. It is not automatically transmitted by the application.
