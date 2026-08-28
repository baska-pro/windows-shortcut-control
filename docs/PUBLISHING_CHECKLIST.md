# Publishing Checklist

Use this checklist before every public release.

## Source

- [ ] Update `$script:AppVersion`.
- [ ] Test first launch.
- [ ] Test Indonesian UI.
- [ ] Test English UI.
- [ ] Test Add/Edit/Delete shortcut.
- [ ] Test drag & drop.
- [ ] Test Command Palette.
- [ ] Test System Tray.
- [ ] Test global hotkey.
- [ ] Test startup registration.
- [ ] Test full backup and restore.
- [ ] Run Self Diagnostics.

## Privacy

- [ ] Search source for phone numbers.
- [ ] Search source for email addresses.
- [ ] Search for passwords, tokens, API keys, and private URLs.
- [ ] Check screenshots for private file paths or account information.
- [ ] Do not commit exported `.wsc.json` backups.

## Documentation

- [ ] Update README.
- [ ] Update CHANGELOG.
- [ ] Add current screenshots.
- [ ] Verify version badge.
- [ ] Verify links.

## GitHub Release

Suggested tag:

```text
v3.2.1
```

Suggested title:

```text
Windows Shortcut Control v3.2.1
```

Attach:

```text
Windows_Shortcut_Control.cmd
```

Optional:

```text
Windows-Shortcut-Control-v3.2.1.zip
```
