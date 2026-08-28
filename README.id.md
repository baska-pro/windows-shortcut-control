# Windows Shortcut Control

<p align="center">
  <strong>Launcher produktivitas & pusat kontrol Windows portable</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows11&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Versi-3.2.1-111827?style=flat-square" alt="Versi 3.2.1">
  <img src="https://img.shields.io/badge/Portable-Satu%20File-16A34A?style=flat-square" alt="Portable">
  <img src="https://img.shields.io/badge/Bahasa-ID%20%7C%20EN-9333EA?style=flat-square" alt="Indonesia dan English">
</p>

<p align="center">
  <a href="./README.md">English</a>
  ·
  <a href="./docs/USER_GUIDE.md">Panduan</a>
  ·
  <a href="./CHANGELOG.md">Changelog</a>
  ·
  <a href="./SECURITY.md">Security</a>
</p>

---

## Tentang Project

**Windows Shortcut Control** adalah launcher dan pusat kontrol Windows portable yang dikemas sebagai satu file `.cmd` dengan PowerShell/WPF tertanam di dalamnya.

Aplikasi menyatukan shortcut pribadi, Windows Tools, informasi sistem, backup/recovery, startup Windows, System Tray, pencarian global, dan navigasi keyboard dalam satu antarmuka.

Tidak memerlukan installer atau dependency eksternal pada instalasi Windows desktop standar.

## Fitur Utama

- GUI WPF modern
- Distribusi portable satu file
- Dashboard untuk item pin, favorit, dan terbaru
- Shortcut Folder, File, App, URL, dan PowerShell
- Drag & drop file/folder
- Tampilan Grid, List, dan Compact
- Pencarian dan filter
- Global Search
- Command Palette
- Windows Tools bawaan
- System Info dan Live Monitor
- System Tray
- Jalankan otomatis saat login Windows
- Pengaturan fungsi tombol Close
- Global hotkey
- Import/export JSON
- Backup/restore konfigurasi lengkap
- Last Known Good recovery
- Self Diagnostics
- Single-instance activation
- Bahasa Indonesia dan English

## Screenshot

<p align="center">
  <img src="./assets/screenshots/dashboard.JPG" width="92%" alt="Dashboard Windows Shortcut Control">
</p>

<p align="center">
  <sub>Dashboard — shortcut pin, favorit, item terbaru, dan akses cepat.</sub>
</p>

<table>
  <tr>
    <td width="50%" align="center">
      <img src="./assets/screenshots/shortcuts.JPG" width="100%" alt="Pengelola Shortcut"><br>
      <strong>Pengelola Shortcut</strong>
    </td>
    <td width="50%" align="center">
      <img src="./assets/screenshots/windows-tools.JPG" width="100%" alt="Windows Tools"><br>
      <strong>Windows Tools</strong>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <img src="./assets/screenshots/settings.JPG" width="100%" alt="Pengaturan"><br>
      <strong>Pengaturan</strong>
    </td>
    <td width="50%" align="center">
      <img src="./assets/screenshots/guide.JPG" width="100%" alt="Panduan bawaan"><br>
      <strong>Panduan Bawaan</strong>
    </td>
  </tr>
</table>

Screenshot lainnya tersedia di [`assets/screenshots/`](./assets/screenshots/).

## Windows Tools

| Kategori | Tools |
|---|---|
| File & Folder | File Explorer, Downloads, Desktop, Documents, Recycle Bin |
| System | Task Manager, Control Panel, Windows Settings, System Information, Resource Monitor |
| Management | Services, Task Scheduler, Device Manager, Disk Management, Event Viewer, Registry Editor |
| Network | Network Connections |
| Terminal | PowerShell, Command Prompt |
| Data & Recovery | Import/export, full backup/restore, Last Known Good, reset, diagnostics, Registry data |

## Persyaratan

- Windows 10 atau Windows 11 desktop
- Windows PowerShell 5.1 atau lebih baru
- Komponen WPF/.NET bawaan Windows desktop
- **Tidak perlu Administrator untuk penggunaan normal**
- Beberapa tool administrasi atau shortcut tertentu dapat meminta elevasi/UAC

> Launcher `.cmd` menjalankan `powershell.exe` menggunakan `ExecutionPolicy Bypass` untuk mengeksekusi kode aplikasi yang tertanam. Selalu periksa source sebelum menjalankan file yang diunduh dari Internet.

## Cara Menjalankan

1. Download `Windows_Shortcut_Control.cmd`.
2. Simpan di folder permanen.
3. Double-click file tersebut.
4. Ikuti atau lewati panduan awal.
5. Jika diperlukan, aktifkan **Jalankan otomatis saat login Windows** melalui Settings.

### Penting

Jika startup Windows sudah diaktifkan, jangan memindahkan atau mengganti nama file `.cmd` tanpa memperbarui konfigurasi startup.

## Penyimpanan Data

Shortcut dan Settings disimpan per-user pada Registry:

```text
HKEY_CURRENT_USER\Software\LaviControlCenter
```

Format export:

```text
Backup shortcut       → *.json
Backup konfigurasi    → *.wsc.json
```

Versi ini tidak berisi telemetry atau request API keluar otomatis. URL dan command dijalankan ketika dipilih oleh pengguna atau melalui shortcut yang pengguna konfigurasi.

Baca [Privacy](./docs/PRIVACY.md).

## Shortcut Keyboard

| Tombol | Fungsi |
|---|---|
| `Ctrl + K` | Command Palette |
| `Ctrl + N` | Tambah shortcut |
| `Ctrl + F` | Global Search |
| `Ctrl + Shift + F` | Cari shortcut |
| `Ctrl + E` | Export shortcut |
| `Ctrl + I` | Import shortcut |
| `Ctrl + B` | Backup konfigurasi |
| `Ctrl + Shift + B` | Restore konfigurasi |
| `Ctrl + Shift + D` | Self Diagnostics |
| `Ctrl + Shift + A` | About |
| `Ctrl + Shift + T` | Minimize ke System Tray |
| `Ctrl + ,` | Settings |
| `Alt + 1` | Dashboard |
| `Alt + 2` | Shortcuts |
| `Alt + 3` | Windows Tools |
| `Alt + 4` | System Info |
| `Alt + 5` | Settings |
| `F1` | Panduan |
| `F5` | Refresh |
| `Ctrl + Alt + Space` | Global hotkey jika diaktifkan |

## Status

Versi publik saat ini:

```text
3.2.1
```

## Lisensi

Copyright © 2026 Lathif Baska.

Repository ini menggunakan **All Rights Reserved**, sesuai dengan copyright notice yang saat ini terdapat di dalam aplikasi.

Baca [LICENSE](./LICENSE).

## Pengembang

**Lathif Baska**

- GitHub: [@baska-pro](https://github.com/baska-pro)
- Indonesia
