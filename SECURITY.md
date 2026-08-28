# Security Policy

## Supported Version

Security reports should target the latest public version.

| Version | Supported |
|---|---|
| 3.2.x | Yes |
| Older builds | Best effort |

## Reporting a Vulnerability

Do **not** post sensitive security details, credentials, private paths, exported
configurations, or personal data in a public GitHub Issue.

Preferred options:

1. Use GitHub's private vulnerability reporting / Security Advisory feature if enabled.
2. Otherwise contact the maintainer through the GitHub profile and request a private channel.

Maintainer:

- https://github.com/baska-pro

## Security Characteristics

Windows Shortcut Control is a local Windows utility. It can intentionally:

- launch applications and files;
- open URLs;
- execute user-created PowerShell commands;
- launch selected shortcuts with elevated privileges;
- open Windows administration tools;
- write settings and shortcut data to the current user's Registry;
- register itself in the current user's startup configuration;
- import JSON configuration files.

Because imported shortcuts may contain commands or paths, only import backup
files that you trust.

## Download Safety

For public releases:

- download files from this repository or its GitHub Releases page;
- verify the release version;
- review the source if required by your environment;
- do not run modified copies from unknown mirrors.

## Sensitive Data

Never attach exported configuration files to a public issue before reviewing them.
They may contain local file paths, URLs, commands, names, and other user-defined data.
