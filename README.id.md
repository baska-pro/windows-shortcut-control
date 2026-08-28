# Windows Shortcut Control

<p align="center">
  <strong>Launcher produktivitas & pusat kontrol Windows portable</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-7%20SP1%20%7C%2010%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Windows 7 SP1, 10 dan 11">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Versi-3.2.1-111827?style=flat-square" alt="Versi 3.2.1">
  <img src="https://img.shields.io/badge/Portable-Satu%20File-16A34A?style=flat-square" alt="Portable">
  <img src="https://img.shields.io/badge/Bahasa-ID%20%7C%20EN-9333EA?style=flat-square" alt="Indonesia dan English">
</p>

<p align="center">
  <a href="https://github.com/baska-pro/windows-shortcut-control/releases/latest">
    <img src="https://img.shields.io/github/v/release/baska-pro/windows-shortcut-control?style=for-the-badge&label=Download%20Terbaru" alt="Download release terbaru">
  </a>
  <a href="https://github.com/baska-pro/windows-shortcut-control/releases">
    <img src="https://img.shields.io/github/downloads/baska-pro/windows-shortcut-control/total?style=for-the-badge&label=Downloads" alt="Total download">
  </a>
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

Pada Windows 10/11 normal, aplikasi tidak memerlukan installer atau dependency eksternal tambahan. Windows 7 juga didukung selama PowerShell dan komponen .NET/WPF yang diperlukan tersedia.

## Kompatibilitas

| Platform | Status | Keterangan |
|---|---|---|
| Windows 11 | ✅ Didukung | Target Windows modern utama |
| Windows 10 | ✅ Didukung | Didukung |
| Windows 7 SP1 | ✅ Sudah diuji | Membutuhkan Windows PowerShell 5.1 dan komponen .NET/WPF yang kompatibel |
| Windows Server | ⚠️ Bukan target utama | Fitur desktop/WPF bergantung pada komponen GUI yang terpasang |

> Windows 7 tidak membawa Windows PowerShell 5.1 secara default. Jika diperlukan, instal **Windows Management Framework 5.1** terlebih dahulu.


## Download, Clone & Instalasi dari GitHub

Ada tiga cara mudah untuk mendapatkan Windows Shortcut Control ke PC.

### Opsi 1 — Download Release Terbaru (Disarankan)

Ini cara paling mudah dan **tidak membutuhkan Git**.

1. Buka [release terbaru](https://github.com/baska-pro/windows-shortcut-control/releases/latest).
2. Pada bagian **Assets**, download:

```text
Windows_Shortcut_Control.cmd
```

3. Simpan file ke folder permanen, misalnya:

```text
C:\Tools\Windows-Shortcut-Control\
```

4. Double-click `Windows_Shortcut_Control.cmd`.

Jika Windows memblokir file hasil download, klik kanan file → **Properties** → aktifkan **Unblock** jika opsi tersebut tersedia → **Apply**.

Bisa juga menggunakan PowerShell:

```powershell
Unblock-File -Path "C:\Tools\Windows-Shortcut-Control\Windows_Shortcut_Control.cmd"
```

### Opsi 2 — Download Repository sebagai ZIP

Tidak perlu menginstal Git.

1. Buka repository:
   `https://github.com/baska-pro/windows-shortcut-control`
2. Klik tombol **Code**.
3. Pilih **Download ZIP**.
4. Extract file ZIP.
5. Buka folder hasil extract.
6. Jalankan:

```text
Windows_Shortcut_Control.cmd
```

Metode ini juga mengunduh README, dokumentasi, screenshot, changelog, dan file repository lainnya.

### Opsi 3 — Clone Menggunakan Git

Gunakan metode ini jika ingin menyimpan repository secara lokal dan mudah melakukan update.

Buka **Command Prompt**, **PowerShell**, atau **Windows Terminal**, lalu jalankan:

```bash
git clone https://github.com/baska-pro/windows-shortcut-control.git
cd windows-shortcut-control
```

Kemudian jalankan:

```cmd
Windows_Shortcut_Control.cmd
```

Atau dari PowerShell:

```powershell
.\Windows_Shortcut_Control.cmd
```

Untuk memperbarui repository yang sudah pernah di-clone:

```bash
git pull
```

> Jika Git belum terpasang, gunakan metode Release atau Download ZIP.

## Instalasi / Menjalankan Pertama Kali

Windows Shortcut Control merupakan **aplikasi portable**, jadi tidak memiliki installer tradisional.

Setup yang disarankan:

1. Simpan `Windows_Shortcut_Control.cmd` di folder permanen.
2. Jalankan file tersebut.
3. Ikuti atau lewati panduan penggunaan pertama.
4. Tambahkan atau import shortcut.
5. Buka **Settings** jika ingin:
   - menjalankan aplikasi otomatis saat login Windows;
   - memulai aplikasi langsung di System Tray;
   - mengatur fungsi tombol Close;
   - mengaktifkan global hotkey;
   - memilih Bahasa Indonesia atau English;
   - membuat backup konfigurasi.

Contoh lokasi yang disarankan:

```text
C:\Tools\Windows-Shortcut-Control\
```

### Opsional — Shortcut Desktop

Klik kanan `Windows_Shortcut_Control.cmd` → **Send to → Desktop (create shortcut)**.

### Opsional — Jalankan Otomatis Saat Login

Startup dapat diaktifkan langsung dari menu **Settings** aplikasi.

Jika startup sudah diaktifkan, usahakan file `.cmd` tetap berada di lokasi yang sama. Memindahkan atau mengganti nama file setelah itu dapat membuat path startup tidak valid.


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

> Ketersediaan Windows Tools tertentu bergantung pada versi Windows. Beberapa tool atau halaman Settings yang tersedia pada Windows 10/11 mungkin tidak tersedia pada Windows 7.

## Persyaratan

### Windows 10 / 11

- Windows 10 atau Windows 11 desktop
- Windows PowerShell 5.1 atau lebih baru
- Komponen WPF/.NET bawaan Windows desktop

### Windows 7

- Windows 7 SP1
- Windows PowerShell 5.1
- Windows Management Framework 5.1 jika PowerShell 5.1 belum terpasang
- .NET Framework/WPF yang kompatibel

**Administrator tidak diperlukan untuk penggunaan normal.** Beberapa tool administrasi atau shortcut tertentu dapat meminta elevasi/UAC.

> Launcher `.cmd` menjalankan `powershell.exe` menggunakan `ExecutionPolicy Bypass` untuk mengeksekusi kode aplikasi yang tertanam. Selalu periksa source sebelum menjalankan file yang diunduh dari Internet.

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

Project aktif dipelihara dan telah diuji pada Windows 7 SP1 serta Windows versi modern.

## Issues & Feature Requests

Gunakan GitHub Issues untuk:

- bug yang dapat direproduksi;
- masalah kompatibilitas;
- permintaan fitur;
- saran UI/UX.

Untuk laporan kompatibilitas Windows 7, sertakan:

- edisi dan arsitektur Windows 7;
- konfirmasi bahwa SP1 sudah terpasang;
- versi PowerShell (`$PSVersionTable.PSVersion`);
- hasil Self Diagnostics yang relevan.

Jangan mengirim password, token, private path, backup pribadi, atau informasi sensitif lainnya ke public issue.

## Lisensi

Copyright © 2026 Lathif Baska.

Repository ini menggunakan **All Rights Reserved**, sesuai dengan copyright notice yang saat ini terdapat di dalam aplikasi.

Baca [LICENSE](./LICENSE).

## Pengembang

**Lathif Baska**

- GitHub: [@baska-pro](https://github.com/baska-pro)
- Indonesia
