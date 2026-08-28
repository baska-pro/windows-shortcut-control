@echo off
setlocal
set "LAVI_CONTROL_CENTER_SELF=%~f0"
set "LAVI_WSC_STARTUP=0"
if /I "%~1"=="--startup" set "LAVI_WSC_STARTUP=1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$ErrorActionPreference='Stop'; try { $self=$env:LAVI_CONTROL_CENTER_SELF; $raw=[IO.File]::ReadAllText($self); $m=('###<LAVI_'+'POWERSHELL>###'); $i=$raw.LastIndexOf($m); if($i -lt 0){throw 'Embedded application code not found.'}; $code=$raw.Substring($i+$m.Length); Invoke-Expression $code } catch { Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue; [System.Windows.MessageBox]::Show($_.Exception.ToString(),'Windows Shortcut Control - Error','OK','Error') | Out-Null }"
exit /b
###<LAVI_POWERSHELL>###
<#
Windows Shortcut Control
Single-file Windows launcher / file control center
Compatible with Windows PowerShell 5.1+ and PowerShell 7 on Windows.

Features:
- Modern WPF GUI
- Dashboard / Favorites / File & Folder launcher / Tools / System info
- Add custom shortcut for Folder, File, App, URL, or PowerShell command
- Double-click shortcut to launch
- Right-click shortcut to Open / Copy target / Open parent folder / Edit / Delete
- Drag window from top bar
- Search/filter shortcuts
- Persistent shortcuts stored in HKCU Registry (no JSON/config file needed)
- Built-in utility actions: Explorer, Downloads, Documents, Desktop, Terminal, Task Manager,
  Control Panel, Windows Settings, Services, Task Scheduler, Network Connections,
  Recycle Bin, System Information, PowerShell, CMD
- Status bar with live date/time and machine/user information
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------
# APP CONSTANTS
# ----------------------------
$script:AppName = 'Windows Shortcut Control'
$script:AppVersion = '3.2.1'
$script:RegistryPath = 'HKCU:\Software\LaviControlCenter'
$script:ShortcutsValueName = 'ShortcutsJson'
$script:SelectedShortcutId = $null
$script:LastPage = 'Dashboard'
$script:LastNonSearchPage = 'Dashboard'
$script:ToolCatalog = @()
$script:ShortcutStore = @()
$script:UpdatingShortcutCategory = $false
$script:SystemInfoCache = $null
$script:SystemInfoPollTimer = $null
$script:SystemInfoLoading = $false
$script:BackgroundRunspacePool = $null
$script:SystemInfoPowerShell = $null
$script:SystemInfoAsyncResult = $null
$script:SystemMonitorPowerShell = $null
$script:SystemMonitorAsyncResult = $null
$script:SystemMonitorTimer = $null
$script:SystemMonitorEnabled = $false
$script:SettingsValueName = 'SettingsJson'
$script:AppSettings = $null
$script:UpdatingSettings = $false
$script:TrayIcon = $null
$script:TrayMenu = $null
$script:TrayAppIcon = $null
$script:WindowLogoSource = $null
$script:TrayKeepAliveTimer = $null
$script:FirstRunGuideTimer = $null
$script:AllowWindowClose = $false
$script:GlobalHotkeySource = $null
$script:GlobalHotkeyHook = $null
$script:GlobalHotkeyRegistered = $false
$script:GlobalHotkeyId = 0x4A71
$script:IsStartupLaunch = ([string]$env:LAVI_WSC_STARTUP -eq '1')
$script:ActivationEventName = 'Local\WindowsShortcutControl_Activate'
$script:ActivationEvent = $null
$script:ActivationTimer = $null
$script:OwnsAppMutex = $false
$script:AppMutex = $null
try {
    $createdNew = $false
    $script:AppMutex = New-Object System.Threading.Mutex(
        $true,
        'Local\WindowsShortcutControl_SingleInstance',
        [ref]$createdNew
    )

    if ($createdNew) {
        $script:OwnsAppMutex = $true
    }
    else {
        # v2.6.1+ instances publish an activation event. A second launch
        # signals the existing window instead of silently refusing to open.
        $activationSent = $false

        try {
            $existingEvent = [System.Threading.EventWaitHandle]::OpenExisting(
                $script:ActivationEventName
            )
            [void]$existingEvent.Set()
            $existingEvent.Dispose()
            $activationSent = $true
        } catch {}

        if ($activationSent) {
            exit
        }

        # Compatibility recovery:
        # an older v2.6 instance may be hidden without a working tray and owns
        # the old mutex but has no activation event. Continue without owning
        # the mutex so this fixed build can still open and repair startup.
        $script:OwnsAppMutex = $false
    }

    $createdActivationEvent = $false
    $script:ActivationEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        $script:ActivationEventName,
        [ref]$createdActivationEvent
    )
} catch {
    $script:OwnsAppMutex = $false
}



function Ensure-RegistryPath {
    if (-not (Test-Path $script:RegistryPath)) {
        New-Item -Path $script:RegistryPath -Force | Out-Null
    }
}

function Get-DefaultShortcuts {
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $desktop = [Environment]::GetFolderPath('Desktop')
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $downloads = Join-Path $userHome 'Downloads'

    @(
        [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); Name='Desktop'; Type='Folder'; Target=$desktop; Icon='🖥'; Category='Quick Access' }
        [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); Name='Documents'; Type='Folder'; Target=$documents; Icon='📄'; Category='Quick Access' }
        [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); Name='Downloads'; Type='Folder'; Target=$downloads; Icon='⬇'; Category='Quick Access' }
        [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); Name='File Explorer'; Type='App'; Target='explorer.exe'; Icon='📁'; Category='Windows' }
        [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); Name='PowerShell'; Type='App'; Target='powershell.exe'; Icon='>_'; Category='Windows' }
        [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); Name='Task Manager'; Type='App'; Target='taskmgr.exe'; Icon='▣'; Category='Windows' }
    )
}

function Get-SafePropertyValue {
    param(
        [object]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }

    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -ne $prop) {
            return $prop.Value
        }
    } catch {}

    return $Default
}

function Get-AppSelfPath {
    try {
        $selfPath = [Environment]::GetEnvironmentVariable('LAVI_CONTROL_CENTER_SELF')
        if (-not [string]::IsNullOrWhiteSpace($selfPath)) {
            return [string]$selfPath
        }
    } catch {}

    try {
        if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            return [string](Join-Path $PSScriptRoot 'Windows_Shortcut_Control.cmd')
        }
    } catch {}

    return ''
}

$script:L10nPairs = @(
    @('Launcher & ruang kerja Windows','Launcher & Windows workspace'),
    @('Cari semua shortcut dan Windows Tools','Search all shortcuts and Windows Tools'),
    @('Cari shortcut atau Windows Tools...','Search shortcuts or Windows Tools...'),
    @('Bersihkan pencarian','Clear search'),
    @('Minimalkan','Minimize'),
    @('Maksimalkan / Pulihkan','Maximize / Restore'),
    @('Tutup','Close'),
    @('RUANG KERJA','WORKSPACE'),
    @('Dashboard','Dashboard'),
    @('Shortcut','Shortcuts'),
    @('Alat Windows','Windows Tools'),
    @('Info Sistem','System Info'),
    @('Pengaturan','Settings'),
    @('Lokasi Aplikasi','Application Location'),
    @('Tentang','About'),
    @('Pinned, favorit, dan shortcut terakhir yang digunakan.','Pinned, favorites, and recently used shortcuts.'),
    @('+ Tambah Shortcut','+ Add Shortcut'),
    @('SHORTCUT','SHORTCUTS'),
    @('tersimpan','saved'),
    @('KOMPUTER','COMPUTER'),
    @('WAKTU','TIME'),
    @('Tip: tarik file atau folder ke jendela ini untuk membuat shortcut otomatis. Command Palette: Ctrl+K.','Tip: drag files or folders into this window to create shortcuts automatically. Command Palette: Ctrl+K.'),
    @('Dipin','Pinned'),
    @('Shortcut yang sengaja dipasang di Dashboard.','Shortcuts intentionally pinned to the Dashboard.'),
    @('Favorit','Favorites'),
    @('Shortcut favorit untuk akses cepat.','Favorite shortcuts for quick access.'),
    @('Terbaru','Recent'),
    @('Shortcut yang terakhir dibuka dari aplikasi.','Shortcuts most recently opened from the application.'),
    @('Shortcut Saya','My Shortcuts'),
    @('Kelola, cari, filter, dan ubah mode tampilan shortcut.','Manage, search, filter, and change shortcut view modes.'),
    @('Ekspor','Export'),
    @('Impor','Import'),
    @('+ Tambah','+ Add'),
    @('Cari nama, tipe, kategori, atau target','Search name, type, category, or target'),
    @('Filter tipe','Filter by type'),
    @('Semua Tipe','All Types'),
    @('Folder','Folder'),
    @('File','File'),
    @('App','App'),
    @('URL','URL'),
    @('PowerShell','PowerShell'),
    @('Filter kategori','Filter by category'),
    @('Semua Kategori','All Categories'),
    @('Filter status','Filter by status'),
    @('Semua','All'),
    @('Dipin','Pinned'),
    @('Sering Dibuka','Most Used'),
    @('Mode tampilan','View mode'),
    @('Kisi','Grid'),
    @('Daftar','List'),
    @('Ringkas','Compact'),
    @('Windows Tools & Data','Windows Tools & Data'),
    @('Cari dan filter utility Windows, terminal, network, serta maintenance data.','Search and filter Windows utilities, terminals, network tools, and data maintenance.'),
    @('Cari Windows Tools','Search Windows Tools'),
    @('File & Folder','File & Folder'),
    @('Sistem','System'),
    @('Manajemen','Management'),
    @('Jaringan','Network'),
    @('Terminal','Terminal'),
    @('Data & Pemulihan','Data & Recovery'),
    @('Hasil Pencarian','Search Results'),
    @('0 hasil','0 results'),
    @('Ringkasan perangkat dan sistem operasi Windows.','Summary of the device and Windows operating system.'),
    @('Perbarui','Refresh'),
    @('Monitor Langsung','Live Monitor'),
    @('Aktif hanya saat halaman System Info dibuka.','Active only while the System Info page is open.'),
    @('Standby','Standby'),
    @('NETWORK','NETWORK'),
    @('Komputer','Computer'),
    @('Pengguna','User'),
    @('Windows','Windows'),
    @('Versi','Version'),
    @('Waktu Aktif','Uptime'),
    @('Disk','Disk'),
    @('Memuat System Info','Loading System Info'),
    @('Membaca CPU, RAM, uptime, dan disk...','Reading CPU, RAM, uptime, and disks...'),
    @('Atur startup Windows, System Tray, perilaku tombol Close, dan global hotkey.','Configure Windows startup, System Tray, Close button behavior, and global hotkey.'),
    @('Startup & Window','Startup & Window'),
    @('Atur bagaimana aplikasi berjalan saat masuk Windows dan ketika jendela ditutup.','Configure how the application runs when you sign in to Windows and when the window is closed.'),
    @('Jalankan otomatis saat login Windows','Run automatically at Windows sign-in'),
    @('Mulai langsung di System Tray','Start directly in System Tray'),
    @('Saat tombol Close ditekan','When the Close button is pressed'),
    @('Keluar dari aplikasi','Exit the application'),
    @('Minimize ke System Tray','Minimize to System Tray'),
    @('Hotkey Global','Global Hotkey'),
    @('Buka Windows Shortcut Control dari aplikasi mana pun.','Open Windows Shortcut Control from any application.'),
    @('Aktifkan Ctrl + Alt + Space','Enable Ctrl + Alt + Space'),
    @('Status: belum diterapkan','Status: not applied yet'),
    @('Status: aktif','Status: active'),
    @('Status: menunggu / belum terdaftar','Status: waiting / not registered'),
    @('Status: nonaktif','Status: disabled'),
    @('Bantuan & Panduan','Help & Guide'),
    @('Buka kembali panduan kapan saja untuk mempelajari menu utama dan cara penggunaan aplikasi.','Reopen the guide at any time to learn the main menus and how to use the application.'),
    @('Panduan Penggunaan','User Guide'),
    @('Backup & Diagnostik','Backup & Diagnostics'),
    @('Backup semua shortcut + settings, restore, atau periksa kesehatan aplikasi.','Back up all shortcuts and settings, restore them, or check application health.'),
    @('Backup Config','Backup Config'),
    @('Restore Config','Restore Config'),
    @('Self Diagnostics','Self Diagnostics'),
    @('Diagnostics belum dijalankan.','Diagnostics have not been run.'),
    @('System Tray tetap menjaga aplikasi aktif tanpa memenuhi taskbar. Global hotkey akan membuka aplikasi sekaligus Command Palette.','System Tray keeps the application active without occupying the taskbar. The global hotkey opens the application together with Command Palette.'),
    @('Test System Tray','Test System Tray'),
    @('Simpan Settings','Save Settings'),
    @('Siap','Ready'),
    @('Bahasa Aplikasi','Application Language'),
    @('Pilih bahasa untuk seluruh menu, tombol, keterangan, dialog, dan panduan.','Choose the language for all menus, buttons, descriptions, dialogs, and guides.'),
    @('Bahasa Indonesia','Bahasa Indonesia'),
    @('English','English'),
    @('Buka','Open'),
    @('Buka Lokasi / Parent Folder','Open Location / Parent Folder'),
    @('Salin Target','Copy Target'),
    @('Lepas dari Dashboard','Unpin from Dashboard'),
    @('Pin ke Dashboard','Pin to Dashboard'),
    @('Hapus dari Favorit','Remove from Favorites'),
    @('Tambah ke Favorit','Add to Favorites'),
    @('Buka Terminal di Lokasi','Open Terminal Here'),
    @('Jalankan sebagai Administrator','Run as Administrator'),
    @('Duplikat Shortcut','Duplicate Shortcut'),
    @('Pindah ke Atas','Move Up'),
    @('Pindah ke Bawah','Move Down'),
    @('Edit Shortcut','Edit Shortcut'),
    @('Hapus Shortcut','Delete Shortcut'),
    @('Target tersedia','Target available'),
    @('Target tidak ditemukan / belum valid','Target not found / not valid'),
    @('Tidak ada shortcut yang cocok dengan filter.','No shortcuts match the current filter.'),
    @('Tidak ada Windows Tool yang cocok dengan filter.','No Windows Tools match the current filter.'),
    @('Belum ada shortcut yang dipin. Klik kanan shortcut > Pin ke Dashboard.','No pinned shortcuts yet. Right-click a shortcut > Pin to Dashboard.'),
    @('Belum ada favorit. Klik kanan shortcut > Tambah ke Favorit.','No favorites yet. Right-click a shortcut > Add to Favorites.'),
    @('Belum ada riwayat. Shortcut yang dibuka akan muncul di sini.','No history yet. Opened shortcuts will appear here.'),
    @('Panduan Penggunaan Indonesia','Indonesian User Guide'),
    @('Sebelumnya','Back'),
    @('Berikutnya','Next'),
    @('Lewati Panduan','Skip Guide'),
    @('Tutup Panduan','Close Guide'),
    @('Selesai','Finish'),
    @('TIPS','TIPS'),
    @('LANGKAH','STEP'),
    @('Buka Dashboard','Open Dashboard'),
    @('Buka Shortcuts','Open Shortcuts'),
    @('Buka Windows Tools','Open Windows Tools'),
    @('Buka System Info','Open System Info'),
    @('Buka Settings','Open Settings'),
    @('Shortcut Keyboard','Keyboard Shortcuts'),
    @('Kategori','Category'),
    @('Aksi','Action'),
    @('Tutup','Close'),
    @('Nama','Name'),
    @('Lokasi','Location'),
    @('Peran','Role'),
    @('Dibuat','Created'),
    @('Platform','Platform'),
    @('Teknologi','Technology'),
    @('Distribusi','Distribution'),
    @('Tentang Aplikasi','About the Application'),
    @('Pengembang & Pemilik','Developer & Owner'),
    @('Informasi Aplikasi','Application Information'),
    @('Kepemilikan & Hak Cipta','Ownership & Copyright')
)

$script:L10nPairs += @(
    @('Data & Pemulihan','Data & Recovery'),
    @('Tentang Aplikasi','About the Application'),
    @('Windows Shortcut Control adalah launcher produktivitas dan pusat kontrol Windows yang ringan, dirancang untuk memberikan akses cepat ke aplikasi, file, folder, URL, perintah PowerShell, alat administrasi Windows, informasi sistem, dan koleksi shortcut pribadi dari satu antarmuka terpusat.','Windows Shortcut Control is a lightweight productivity launcher and Windows control center designed to provide fast access to applications, files, folders, URLs, PowerShell commands, Windows administration tools, system information, and personal shortcut collections from one centralized interface.'),
    @('Aplikasi ini dirancang sebagai utilitas Windows portable satu file dengan penyimpanan shortcut persisten, mekanisme recovery, pencarian global, Command Palette, integrasi System Tray, dukungan startup, monitoring sistem langsung, backup/restore, dan self-diagnostics.','The application is designed as a portable single-file Windows utility with persistent shortcut storage, recovery mechanisms, global search, Command Palette, System Tray integration, startup support, live system monitoring, backup/restore, and self-diagnostics.'),
    @('Pengembang & Pemilik','Developer & Owner'),
    @('Nama','Name'),
    @('Media Sosial','Social Media'),
    @('Lokasi','Location'),
    @('Peran','Role'),
    @('Pengembang, Pemilik Produk & Maintainer','Developer, Product Owner & Maintainer'),
    @('Informasi Aplikasi','Application Information'),
    @('Dibuat','Created'),
    @('27 Agustus 2026','August 27, 2026'),
    @('Teknologi','Technology'),
    @('Distribusi','Distribution'),
    @('Aplikasi Portable Satu File','Portable Single-File Application'),
    @('Kepemilikan & Hak Cipta','Ownership & Copyright'),
    @('© 2026 Lathif Baska. Windows Shortcut Control dikembangkan dan dipelihara oleh Lathif Baska. Seluruh hak dilindungi.','© 2026 Lathif Baska. Windows Shortcut Control is developed and maintained by Lathif Baska. All rights reserved.'),
    @('Panduan Penggunaan','Getting Started'),
    @('Akses keyboard cepat untuk navigasi, pencarian, backup, diagnostics, dan kontrol aplikasi.','Quick keyboard access for navigation, search, backup, diagnostics, and application controls.'),
    @('Tips: Ctrl + Alt + Space adalah shortcut global untuk membuka Windows Shortcut Control dari aplikasi lain ketika Global Hotkey diaktifkan di Settings.','Tip: Ctrl + Alt + Space is a global shortcut and can open Windows Shortcut Control from another application when Global Hotkey is enabled in Settings.'),
    @('Windows Shortcut Control · Referensi Keyboard','Windows Shortcut Control · Keyboard Reference'),
    @('Umum','General'),
    @('Navigasi','Navigation'),
    @('Bantuan','Help'),
    @('Buka aplikasi dan Command Palette dari mana saja di Windows.','Open the application and Command Palette from anywhere in Windows.'),
    @('Buka Command Palette.','Open Command Palette.'),
    @('Buat shortcut baru.','Create a new shortcut.'),
    @('Fokus ke Global Search.','Focus Global Search.'),
    @('Buka halaman Shortcuts dan fokus ke pencarian shortcut.','Open Shortcuts page and focus Shortcut Search.'),
    @('Perbarui data dan tampilan aplikasi.','Refresh the current application data and views.'),
    @('Buka Dashboard.','Open Dashboard.'),
    @('Buka Shortcuts.','Open Shortcuts.'),
    @('Buka Windows Tools.','Open Windows Tools.'),
    @('Buka System Info dan Live Monitor.','Open System Info and Live Monitor.'),
    @('Buka Settings.','Open Settings.'),
    @('Buka About.','Open About.'),
    @('Ekspor data shortcut.','Export shortcut data.'),
    @('Impor data shortcut.','Import shortcut data.'),
    @('Buat backup konfigurasi lengkap.','Create a full configuration backup.'),
    @('Pulihkan backup konfigurasi lengkap.','Restore a full configuration backup.'),
    @('Jalankan Self Diagnostics.','Run Self Diagnostics.'),
    @('Minimize Windows Shortcut Control ke System Tray.','Minimize Windows Shortcut Control to System Tray.'),
    @('Pindah pilihan pada hasil Command Palette.','Move through Command Palette results.'),
    @('Jalankan item Command Palette yang dipilih.','Run the selected Command Palette item.'),
    @('Tutup Command Palette.','Close Command Palette.'),
    @('Panduan singkat Windows Shortcut Control','Windows Shortcut Control quick guide'),
    @('Selamat Datang','Welcome'),
    @('Kenali Windows Shortcut Control dalam beberapa langkah singkat.','Learn Windows Shortcut Control in a few quick steps.'),
    @('Windows Shortcut Control adalah launcher dan pusat kontrol Windows untuk membuka aplikasi, file, folder, URL, perintah PowerShell, serta berbagai alat bawaan Windows dari satu tempat.','Windows Shortcut Control is a launcher and Windows control center for opening applications, files, folders, URLs, PowerShell commands, and built-in Windows tools from one place.'),
    @('Gunakan Berikutnya dan Sebelumnya untuk berpindah langkah. Panduan dapat dilewati kapan saja dan bisa dibuka kembali melalui About, Settings, Command Palette, atau tombol F1.','Use Next and Back to move between steps. You can skip the guide at any time and reopen it from About, Settings, Command Palette, or F1.'),
    @('Halaman utama untuk akses cepat.','The main page for quick access.'),
    @('Dashboard menampilkan shortcut yang Anda pin, daftar Favorit, dan shortcut yang terakhir digunakan. Gunakan halaman ini untuk menyimpan item penting agar mudah dijangkau.','Dashboard shows pinned shortcuts, Favorites, and recently used shortcuts. Use this page to keep important items within easy reach.'),
    @('Klik kanan shortcut lalu pilih Pin ke Dashboard atau Tambah ke Favorit. Bagian Terbaru diperbarui otomatis setelah shortcut berhasil dibuka.','Right-click a shortcut and choose Pin to Dashboard or Add to Favorites. Recent items update automatically after a shortcut is opened.'),
    @('Menu Shortcuts','Shortcuts Menu'),
    @('Tempat membuat dan mengelola semua shortcut pribadi.','Create and manage all your personal shortcuts.'),
    @('Halaman Shortcuts dapat menyimpan Folder, File, Aplikasi, URL, dan perintah PowerShell. Gunakan Tambah Shortcut untuk membuatnya secara manual, atau tarik file/folder langsung dari Windows Explorer ke jendela aplikasi.','The Shortcuts page can store folders, files, applications, URLs, and PowerShell commands. Use Add Shortcut to create one manually, or drag files/folders from Windows Explorer into the application.'),
    @('Gunakan pencarian dan filter untuk menemukan shortcut. Klik kanan shortcut untuk Edit, Duplicate, Run as Administrator, Pin, Favorit, Open Location, dan tindakan lainnya.','Use search and filters to find shortcuts. Right-click a shortcut for Edit, Duplicate, Run as Administrator, Pin, Favorites, Open Location, and other actions.'),
    @('Akses cepat ke alat administrasi Windows.','Quick access to Windows administration tools.'),
    @('Windows Tools menyediakan Task Manager, Services, Task Scheduler, Device Manager, Disk Management, Registry Editor, PowerShell, Command Prompt, Network Connections, fitur recovery, backup, dan berbagai alat lainnya.','Windows Tools provides Task Manager, Services, Task Scheduler, Device Manager, Disk Management, Registry Editor, PowerShell, Command Prompt, Network Connections, recovery, backup, and other tools.'),
    @('Gunakan kotak pencarian. Contoh: task untuk Task Manager, device untuk Device Manager, registry untuk Registry Editor, atau backup untuk pencadangan.','Use the search box. For example: task for Task Manager, device for Device Manager, registry for Registry Editor, or backup for backup tools.'),
    @('Lihat informasi komputer dan penggunaan resource secara langsung.','View computer information and resource usage in real time.'),
    @('System Info menampilkan informasi Windows, prosesor, RAM, uptime, dan penyimpanan. Live Monitor memperbarui penggunaan CPU, RAM, kecepatan download, dan upload secara berkala.','System Info shows Windows, processor, RAM, uptime, and storage information. Live Monitor periodically updates CPU, RAM, download, and upload usage.'),
    @('Live Monitor hanya aktif saat halaman System Info dibuka. Ketika pindah halaman, monitoring otomatis berhenti agar aplikasi tetap ringan.','Live Monitor is active only while System Info is open. Monitoring stops automatically when you leave the page to keep the application lightweight.'),
    @('Pencarian & Command Palette','Search & Command Palette'),
    @('Temukan dan jalankan fitur tanpa membuka menu satu per satu.','Find and run features without opening menus one by one.'),
    @('Global Search dapat mencari shortcut dan Windows Tools. Command Palette menyediakan akses cepat ke halaman, shortcut, tools, backup, diagnostics, About, dan berbagai perintah aplikasi.','Global Search can find shortcuts and Windows Tools. Command Palette provides quick access to pages, shortcuts, tools, backup, diagnostics, About, and application commands.'),
    @('Ctrl + F membuka Global Search. Ctrl + K membuka Command Palette. Ctrl + Alt + Space membuka aplikasi sekaligus Command Palette dari aplikasi lain jika Global Hotkey aktif.','Ctrl + F opens Global Search. Ctrl + K opens Command Palette. Ctrl + Alt + Space opens the application and Command Palette from another app when Global Hotkey is enabled.'),
    @('Atur bagaimana aplikasi berjalan di Windows.','Configure how the application runs in Windows.'),
    @('Di Settings Anda dapat mengaktifkan aplikasi saat login Windows, menjalankannya langsung ke System Tray, menentukan fungsi tombol Close, mengatur Global Hotkey, membuka panduan, melakukan backup/restore, dan menjalankan Self Diagnostics.','In Settings you can run the application at Windows sign-in, start directly in System Tray, configure the Close button, manage Global Hotkey, open the guide, backup/restore, and run Self Diagnostics.'),
    @('Walaupun Start in Tray aktif, double-click file aplikasi secara manual tetap membuka jendela utama. Gunakan Ctrl + Shift + T untuk mengirim aplikasi ke System Tray.','Even when Start in Tray is enabled, manually double-clicking the application still opens the main window. Use Ctrl + Shift + T to send it to System Tray.'),
    @('Backup, Recovery & Bantuan','Backup, Recovery & Help'),
    @('Lindungi konfigurasi dan ketahui cara mendapatkan bantuan.','Protect your configuration and know where to get help.'),
    @('Backup Config menyimpan shortcut dan Settings dalam satu file. Last Known Good dan backup Registry membantu memulihkan data jika terjadi masalah. Self Diagnostics memeriksa storage, startup, tray, hotkey, runspace, dan komponen utama lainnya.','Backup Config stores shortcuts and Settings in one file. Last Known Good and Registry backups help recover data if problems occur. Self Diagnostics checks storage, startup, tray, hotkey, runspace, and other core components.'),
    @('Tekan F1 kapan saja untuk membuka panduan ini kembali. Menu About berisi informasi aplikasi dan pengembang. Keyboard Shortcuts berisi daftar lengkap tombol pintas.','Press F1 at any time to reopen this guide. About contains application and developer information. Keyboard Shortcuts contains the complete keyboard reference.'),
    @('Buka Panduan Penggunaan aplikasi.','Open the application User Guide.'),
    @('Cari command, shortcut, atau Windows Tool','Search commands, shortcuts, or Windows Tools'),
    @('↑↓ pilih   Enter jalankan   Esc tutup','↑↓ select   Enter run   Esc close'),
    @('Tambah Shortcut','Add Shortcut'),
    @('Buat shortcut baru','Create a new shortcut'),
    @('Buka halaman Dashboard','Open Dashboard page'),
    @('Buka daftar shortcut','Open shortcut list'),
    @('Buka informasi sistem dan Live Monitor','Open system information and Live Monitor'),
    @('Startup, tray, backup, dan diagnostics','Startup, tray, backup, and diagnostics'),
    @('Application, developer, owner, contact, and creation information','Application, developer, owner, contact, and creation information'),
    @('View all available keyboard shortcuts','View all available keyboard shortcuts'),
    @('Buka panduan menu utama dan cara menggunakan aplikasi','Open the guide to main menus and application usage'),
    @('Backup shortcut + seluruh settings','Back up shortcuts + all settings'),
    @('Restore shortcut + seluruh settings','Restore shortcuts + all settings'),
    @('Periksa kesehatan komponen aplikasi','Check application component health')
)

$script:L10nPairs += @(
    @('Status','Status'),
    @('Pemeriksaan','Check'),
    @('Detail','Detail'),
    @('Salin Laporan','Copy Report'),
    @('Self Diagnostics','Self Diagnostics'),
    @('Pemeriksaan cepat komponen utama Windows Shortcut Control.','Quick check of the main Windows Shortcut Control components.'),
    @('OK','OK'),
    @('Peringatan/Info','Warning/Info'),
    @('Gagal','Fail'),
    @('hasil','results'),
    @('Hasil','Results'),
    @('Cari','Search'),
    @('Tidak ada hasil.','No results.'),
    @('Keluar','Exit'),
    @('Buka Windows Shortcut Control','Open Windows Shortcut Control'),
    @('Bahasa','Language'),
    @('Bahasa aplikasi diperbarui.','Application language updated.'),
    @('Settings berhasil disimpan.','Settings saved successfully.'),
    @('Settings berhasil disimpan dan langsung diterapkan.','Settings were saved and applied immediately.')
)

$script:L10nPairs += @(
    @('Pengelola Shortcut','Shortcut Manager'),
    @('Tambah Shortcut','Add Shortcut'),
    @('Buat akses cepat ke folder, file, aplikasi, website, atau perintah PowerShell.','Create quick access to a folder, file, application, website, or PowerShell command.'),
    @('Nama Shortcut','Shortcut Name'),
    @('Tipe','Type'),
    @('Kategori','Category'),
    @('Target / Lokasi','Target / Location'),
    @('Jelajahi','Browse'),
    @('Uji','Test'),
    @('Masukkan target lalu tekan Test untuk memeriksa.','Enter a target, then press Test to validate it.'),
    @('Folder/File/App: gunakan Browse. URL dapat ditulis seperti example.com dan akan otomatis menjadi https://example.com. PowerShell menerima perintah langsung.','Folder/File/App: use Browse. URLs can be entered as example.com and will automatically become https://example.com. PowerShell accepts direct commands.'),
    @('Semua perubahan disimpan setelah menekan Simpan.','All changes are saved after pressing Save.'),
    @('Batal','Cancel'),
    @('Simpan Shortcut','Save Shortcut'),
    @('Target valid dan siap digunakan.','Target is valid and ready to use.'),
    @('Target belum valid atau tidak ditemukan.','Target is not valid or could not be found.'),
    @('Nama shortcut wajib diisi.','Shortcut name is required.'),
    @('Target wajib diisi.','Target is required.'),
    @('Validasi','Validation')
)

$script:L10nPairs += @(
    @('Status: gagal didaftarkan / sedang digunakan aplikasi lain','Status: registration failed / already used by another application'),
    @('Tidak ada shortcut.','No shortcuts found.'),
    @('Tidak ada Windows Tool.','No Windows Tools found.'),
    @('Aplikasi tetap berjalan di System Tray.','The application is still running in System Tray.'),
    @('Tools','Windows Tools'),
    @('Shortcuts','Shortcuts'),
    @('Search','Search')
)

$script:L10nPairs += @(
    @('Tentang Windows Shortcut Control','About Windows Shortcut Control'),
    @('Launcher Produktivitas & Pusat Kontrol Windows','Productivity Launcher & Windows Control Center')
)

function Get-AppLanguage {
    try {
        if ($null -ne $script:AppSettings) {
            $lang = [string]$script:AppSettings.Language
            if ($lang -in @('id','en')) { return $lang }
        }
    } catch {}
    return 'id'
}

function L([string]$Indonesian, [string]$English) {
    if ((Get-AppLanguage) -eq 'en') { return $English }
    return $Indonesian
}

function Convert-UiText([string]$Text) {
    if ($null -eq $Text) { return $Text }
    $lang = Get-AppLanguage

    foreach ($pair in @($script:L10nPairs)) {
        if ($Text -eq [string]$pair[0] -or $Text -eq [string]$pair[1]) {
            if ($lang -eq 'en') { return [string]$pair[1] }
            return [string]$pair[0]
        }
    }
    return $Text
}

function Get-CanonicalUiValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    switch ($Value) {
        'All Types'       { return 'Semua Tipe' }
        'All Categories'  { return 'Semua Kategori' }
        'All'             { return 'Semua' }
        'Favorites'       { return 'Favorit' }
        'Pinned'          { return 'Dipin' }
        'Recent'          { return 'Terbaru' }
        'Most Used'       { return 'Sering Dibuka' }
        'Sistem'          { return 'System' }
        'Manajemen'       { return 'Management' }
        'Jaringan'        { return 'Network' }
        'Data & Pemulihan'{ return 'Data & Recovery' }
        'Kisi'            { return 'Grid' }
        'Daftar'          { return 'List' }
        'Ringkas'         { return 'Compact' }
        'Data & Recovery' { return 'Data & Recovery' }
        default           { return $Value }
    }
}

function Apply-LanguageToElement([object]$Root) {
    if ($null -eq $Root) { return }

    try {
        $name = ''
        try { $name = [string]$Root.Name } catch {}

        if ($name -in @(
            'ShortcutPanel','DashboardPinned','DashboardFavorites','DashboardRecent',
            'GlobalShortcutPanel','GlobalToolsPanel','ToolsPanel','SysDisks'
        )) {
            return
        }

        if ($Root -is [System.Windows.Window]) {
            try { $Root.Title = Convert-UiText ([string]$Root.Title) } catch {}
        }

        if ($Root -is [System.Windows.Controls.TextBlock]) {
            try { $Root.Text = Convert-UiText ([string]$Root.Text) } catch {}
        }

        if ($Root -is [System.Windows.Controls.ContentControl]) {
            try {
                if ($Root.Content -is [string]) {
                    $Root.Content = Convert-UiText ([string]$Root.Content)
                }
            } catch {}
        }

        if ($Root -is [System.Windows.FrameworkElement]) {
            try {
                if ($Root.ToolTip -is [string]) {
                    $Root.ToolTip = Convert-UiText ([string]$Root.ToolTip)
                }
            } catch {}
        }

        try {
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Root)) {
                if ($child -is [System.Windows.DependencyObject]) {
                    Apply-LanguageToElement $child
                }
            }
        } catch {}
    } catch {}
}

function Apply-AppLanguage {
    try {
        Apply-LanguageToElement $window

        if ($null -ne $script:CmbLanguage) {
            $target = Get-AppLanguage
            for ($i=0; $i -lt $script:CmbLanguage.Items.Count; $i++) {
                $item = $script:CmbLanguage.Items[$i]
                if ([string]$item.Tag -eq $target) {
                    $script:CmbLanguage.SelectedIndex = $i
                    break
                }
            }
        }

        # Rebuild dynamic content in the selected language.
        $script:ToolCatalog = $null
        Initialize-ToolCatalog

        if ($null -ne $script:ShortcutPanel) { Refresh-ShortcutViews }
        if ($null -ne $script:ToolsPanel) { Refresh-ToolViews }
        if ($null -ne $script:DashboardPinned) { Refresh-DashboardViews }

        if ($null -ne $script:TxtGlobalSearch -and
            -not [string]::IsNullOrWhiteSpace([string]$script:TxtGlobalSearch.Text)) {
            Refresh-GlobalSearch
        }

        # Recreate tray menu so its labels follow the selected language.
        try {
            Dispose-SystemTray
            [void](Initialize-SystemTray)
            Start-TrayKeepAlive
        } catch {}

        # Refresh language-dependent runtime status.
        if ($null -ne $script:AppSettings) {
            Apply-GlobalHotkeySetting
        }
    } catch {}
}

function Get-DefaultAppSettings {
    [pscustomobject][ordered]@{
        RunAtStartup        = $false
        StartInTray         = $false
        CloseBehavior       = 'Exit'
        GlobalHotkey        = $true
        OnboardingCompleted = $false
        Language            = 'id'
    }
}

function Normalize-AppSettings([object]$Settings) {
    $defaults = Get-DefaultAppSettings
    if ($null -eq $Settings) { return $defaults }

    $runAtStartup = Convert-ToBoolSafe (Get-SafePropertyValue $Settings 'RunAtStartup' $defaults.RunAtStartup)
    $startInTray = Convert-ToBoolSafe (Get-SafePropertyValue $Settings 'StartInTray' $defaults.StartInTray)
    $globalHotkey = Convert-ToBoolSafe (Get-SafePropertyValue $Settings 'GlobalHotkey' $defaults.GlobalHotkey)
    $onboardingCompleted = Convert-ToBoolSafe (Get-SafePropertyValue $Settings 'OnboardingCompleted' $defaults.OnboardingCompleted)
    $closeBehavior = [string](Get-SafePropertyValue $Settings 'CloseBehavior' $defaults.CloseBehavior)
    $language = [string](Get-SafePropertyValue $Settings 'Language' $defaults.Language)

    if ($closeBehavior -notin @('Exit','Tray')) {
        $closeBehavior = 'Exit'
    }

    if ($language -notin @('id','en')) {
        $language = 'id'
    }

    [pscustomobject][ordered]@{
        RunAtStartup        = $runAtStartup
        StartInTray         = $startInTray
        CloseBehavior       = $closeBehavior
        GlobalHotkey        = $globalHotkey
        OnboardingCompleted = $onboardingCompleted
        Language            = $language
    }
}

function Load-AppSettings {
    Ensure-RegistryPath

    try {
        $reg = Get-ItemProperty -Path $script:RegistryPath -Name $script:SettingsValueName -ErrorAction Stop
        $prop = $reg.PSObject.Properties[$script:SettingsValueName]

        if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            $script:AppSettings = Get-DefaultAppSettings
            Save-AppSettings
            return
        }

        $parsed = ([string]$prop.Value) | ConvertFrom-Json -ErrorAction Stop
        $script:AppSettings = Normalize-AppSettings $parsed
    }
    catch {
        $script:AppSettings = Get-DefaultAppSettings
        try { Save-AppSettings } catch {}
    }
}

function Save-AppSettings {
    Ensure-RegistryPath

    if ($null -eq $script:AppSettings) {
        $script:AppSettings = Get-DefaultAppSettings
    }

    $script:AppSettings = Normalize-AppSettings $script:AppSettings
    $json = ConvertTo-Json -InputObject $script:AppSettings -Depth 4 -Compress

    New-ItemProperty -Path $script:RegistryPath `
        -Name $script:SettingsValueName `
        -Value ([string]$json) `
        -PropertyType String `
        -Force | Out-Null
}

function Set-StartupRegistration([bool]$Enabled) {
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $valueName = 'WindowsShortcutControl'

    try {
        if (-not (Test-Path $runPath)) {
            New-Item -Path $runPath -Force | Out-Null
        }

        if ($Enabled) {
            $selfPath = Get-AppSelfPath
            if ([string]::IsNullOrWhiteSpace($selfPath) -or
                -not (Test-Path -LiteralPath $selfPath -PathType Leaf -ErrorAction SilentlyContinue)) {
                throw 'Lokasi file aplikasi tidak dapat ditemukan. Jalankan aplikasi dari file .cmd yang tersimpan.'
            }

            $command = '"' + $selfPath + '" --startup'
            New-ItemProperty -Path $runPath `
                -Name $valueName `
                -Value $command `
                -PropertyType String `
                -Force | Out-Null
        }
        else {
            Remove-ItemProperty -Path $runPath -Name $valueName -ErrorAction SilentlyContinue
        }

        return $true
    }
    catch {
        Show-Error $_.Exception.Message 'Windows Startup'
        return $false
    }
}


function Get-InferredShortcutType([string]$Target) {
    if ([string]::IsNullOrWhiteSpace($Target)) { return 'File' }

    $expanded = [Environment]::ExpandEnvironmentVariables($Target)

    if ($Target -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { return 'URL' }

    try {
        if (Test-Path -LiteralPath $expanded -PathType Container) { return 'Folder' }
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            $ext = [IO.Path]::GetExtension($expanded)
            if ($ext -match '^(?i)\.(exe|com|bat|cmd|msc|cpl)$') { return 'App' }
            return 'File'
        }
    } catch {}

    if ($expanded -match '(?i)\.(exe|com|bat|cmd|msc|cpl)$') { return 'App' }
    return 'File'
}

function Convert-ToBoolSafe {
    param([object]$Value, [bool]$Default=$false)

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }

    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @('1','true','yes','on')) { return $true }
    if ($s -in @('0','false','no','off','')) { return $false }
    return $Default
}

function Normalize-ShortcutItem {
    param([object]$Item)

    if ($null -eq $Item) { return $null }

    $id       = [string](Get-SafePropertyValue $Item 'Id' '')
    $name     = [string](Get-SafePropertyValue $Item 'Name' '')
    $type     = [string](Get-SafePropertyValue $Item 'Type' '')
    $target   = [string](Get-SafePropertyValue $Item 'Target' '')
    $icon     = [string](Get-SafePropertyValue $Item 'Icon' '')
    $category = [string](Get-SafePropertyValue $Item 'Category' '')

    $favorite = Convert-ToBoolSafe (Get-SafePropertyValue $Item 'Favorite' $false)
    $pinned   = Convert-ToBoolSafe (Get-SafePropertyValue $Item 'Pinned' $false)

    $openCount = 0
    try {
        $openCount = [int](Get-SafePropertyValue $Item 'OpenCount' 0)
        if ($openCount -lt 0) { $openCount = 0 }
    } catch {
        $openCount = 0
    }

    $lastOpened = [string](Get-SafePropertyValue $Item 'LastOpened' '')

    if ([string]::IsNullOrWhiteSpace($target)) {
        foreach ($legacyName in @('Path','FilePath','Command','Url','URL')) {
            $legacyValue = [string](Get-SafePropertyValue $Item $legacyName '')
            if (-not [string]::IsNullOrWhiteSpace($legacyValue)) {
                $target = $legacyValue
                break
            }
        }
    }

    $hasAnyData = (
        -not [string]::IsNullOrWhiteSpace($id) -or
        -not [string]::IsNullOrWhiteSpace($name) -or
        -not [string]::IsNullOrWhiteSpace($type) -or
        -not [string]::IsNullOrWhiteSpace($target) -or
        -not [string]::IsNullOrWhiteSpace($category)
    )
    if (-not $hasAnyData) { return $null }

    if ([string]::IsNullOrWhiteSpace($id)) {
        $id = [guid]::NewGuid().ToString('D')
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            try {
                $leaf = Split-Path -Path $target -Leaf -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $target }
                $name = $leaf
            } catch {
                $name = $target
            }
        } else {
            $name = 'Shortcut'
        }
    }

    if ([string]::IsNullOrWhiteSpace($type)) {
        $type = Get-InferredShortcutType $target
    }

    switch -Regex ($type) {
        '^(?i)(folder|directory|dir)$'         { $type = 'Folder'; break }
        '^(?i)(file|document)$'                { $type = 'File'; break }
        '^(?i)(app|application|exe|program)$'  { $type = 'App'; break }
        '^(?i)(url|web|website|link)$'         { $type = 'URL'; break }
        '^(?i)(powershell|ps|command)$'        { $type = 'PowerShell'; break }
        default {
            if ($type -notin @('Folder','File','App','URL','PowerShell')) {
                $type = Get-InferredShortcutType $target
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Custom' }

    if ([string]::IsNullOrWhiteSpace($icon)) {
        switch ($type) {
            'Folder'     { $icon = 'DIR' }
            'File'       { $icon = 'FILE' }
            'App'        { $icon = 'APP' }
            'URL'        { $icon = 'WEB' }
            'PowerShell' { $icon = 'PS' }
            default      { $icon = 'ITEM' }
        }
    }

    [pscustomobject][ordered]@{
        Id         = $id
        Name       = $name
        Type       = $type
        Target     = $target
        Icon       = $icon
        Category   = $category
        Favorite   = $favorite
        Pinned     = $pinned
        OpenCount  = $openCount
        LastOpened = $lastOpened
    }
}

function Normalize-ShortcutCollection {
    param([object[]]$Items)

    $output = @()
    $seen = @{}

    foreach ($raw in @($Items)) {
        $item = Normalize-ShortcutItem $raw
        if ($null -eq $item) { continue }

        $id = [string]$item.Id
        if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) {
            $item.Id = [guid]::NewGuid().ToString('D')
            $id = [string]$item.Id
        }

        $seen[$id] = $true
        $output += $item
    }

    # Deliberately do NOT use unary comma here.
    # The caller wraps this function in @(...), which preserves 0/1/many items correctly.
    return $output
}

function Expand-LegacyShortcutObjects {
    param([object]$Value)

    if ($null -eq $Value) { return }

    # A real shortcut object has at least one of these properties.
    $shortcutProps = @('Id','Name','Type','Target','Path','FilePath','Command','Url','URL','Category')
    foreach ($propName in $shortcutProps) {
        try {
            if ($null -ne $Value.PSObject.Properties[$propName]) {
                Write-Output $Value
                return
            }
        } catch {}
    }

    # Old buggy versions could store nested JSON arrays such as [[{...},{...}]].
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($child in $Value) {
            Expand-LegacyShortcutObjects $child
        }
    }
}

function Convert-JsonToShortcutItems {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }

    $parsed = $Json | ConvertFrom-Json -ErrorAction Stop

    $schema = [string](Get-SafePropertyValue $parsed 'Schema' '')

    # Compatibility:
    # - LaviControlCenter.Shortcuts       = schema used before app rename
    # - WindowsShortcutControl.Shortcuts = current schema
    if ($schema -in @('LaviControlCenter.Shortcuts','WindowsShortcutControl.Shortcuts')) {
        $items = Get-SafePropertyValue $parsed 'Items' @()
        return @(Normalize-ShortcutCollection @($items))
    }

    # Legacy top-level arrays / nested arrays / plain shortcut object.
    $expanded = @(Expand-LegacyShortcutObjects $parsed)
    return @(Normalize-ShortcutCollection $expanded)
}

function Read-CurrentShortcutJson {
    Ensure-RegistryPath

    $reg = Get-ItemProperty -Path $script:RegistryPath -ErrorAction SilentlyContinue
    if ($null -eq $reg) { return $null }

    $prop = $reg.PSObject.Properties[$script:ShortcutsValueName]
    if ($null -eq $prop) { return $null }

    return [string]$prop.Value
}

function Backup-ShortcutJson {
    param([string]$Json, [string]$Reason='Migration')

    if ([string]::IsNullOrWhiteSpace($Json)) { return }

    try {
        $name = 'ShortcutsJson_Backup_{0}_{1}' -f $Reason, (Get-Date -Format 'yyyyMMdd_HHmmss')
        New-ItemProperty -Path $script:RegistryPath `
            -Name $name `
            -Value $Json `
            -PropertyType String `
            -Force | Out-Null
    } catch {}
}

function Get-RecoverableBackupShortcutItems {
    try {
        $reg = Get-ItemProperty -Path $script:RegistryPath -ErrorAction SilentlyContinue
        if ($null -eq $reg) { return @() }

        $backupProps = @(
            $reg.PSObject.Properties |
            Where-Object { $_.Name -like 'ShortcutsJson_Backup_*' } |
            Sort-Object Name -Descending
        )

        foreach ($prop in $backupProps) {
            try {
                $items = @(Convert-JsonToShortcutItems ([string]$prop.Value))
                $useful = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Target) })
                if ($useful.Count -gt 0) {
                    return $items
                }
            } catch {}
        }
    } catch {}

    return @()
}


function Get-LastKnownGoodShortcutItems {
    try {
        $reg = Get-ItemProperty -Path $script:RegistryPath `
            -Name 'ShortcutsJson_LastKnownGood' -ErrorAction Stop

        $prop = $reg.PSObject.Properties['ShortcutsJson_LastKnownGood']
        if ($null -eq $prop) { return @() }

        $json = [string]$prop.Value
        if ([string]::IsNullOrWhiteSpace($json)) { return @() }

        return @(Convert-JsonToShortcutItems $json)
    } catch {
        return @()
    }
}

function Get-BestRecoverableShortcutItems {
    # Prefer LastKnownGood because transactional save writes the previous
    # valid state there before committing a new one.
    $lkg = @(Get-LastKnownGoodShortcutItems)
    $usefulLkg = @(
        $lkg | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.Target)
        }
    )
    if ($usefulLkg.Count -gt 0) {
        return $lkg
    }

    # Fallback to timestamped migration/repair backups.
    $backup = @(Get-RecoverableBackupShortcutItems)
    $usefulBackup = @(
        $backup | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.Target)
        }
    )
    if ($usefulBackup.Count -gt 0) {
        return $backup
    }

    return @()
}

function Save-ShortcutStore {
    Ensure-RegistryPath

    $serialItems = @()
    foreach ($item in @($script:ShortcutStore)) {
        if ($null -eq $item) { continue }
        $serialItems += [pscustomobject][ordered]@{
            Id         = [string]$item.Id
            Name       = [string]$item.Name
            Type       = [string]$item.Type
            Target     = [string]$item.Target
            Icon       = [string]$item.Icon
            Category   = [string]$item.Category
            Favorite   = [bool]$item.Favorite
            Pinned     = [bool]$item.Pinned
            OpenCount  = [int]$item.OpenCount
            LastOpened = [string]$item.LastOpened
        }
    }

    $envelope = [pscustomobject][ordered]@{
        Schema  = 'WindowsShortcutControl.Shortcuts'
        Version = 4
        SavedAt = (Get-Date).ToString('o')
        Items   = $serialItems
    }
    $json = ConvertTo-Json -InputObject $envelope -Depth 8 -Compress

    # Transaction-like Registry save: Pending -> verify -> LastKnownGood -> commit.
    $pendingName = 'ShortcutsJson_Pending'
    New-ItemProperty -Path $script:RegistryPath -Name $pendingName -Value ([string]$json) -PropertyType String -Force | Out-Null

    $pending = [string](Get-ItemProperty -Path $script:RegistryPath -Name $pendingName -ErrorAction Stop).PSObject.Properties[$pendingName].Value
    $verifiedItems = @(Convert-JsonToShortcutItems $pending)
    if ($verifiedItems.Count -ne $serialItems.Count) {
        throw "Verifikasi penyimpanan gagal. Expected $($serialItems.Count), terbaca $($verifiedItems.Count)."
    }

    $oldJson = Read-CurrentShortcutJson
    if (-not [string]::IsNullOrWhiteSpace($oldJson)) {
        New-ItemProperty -Path $script:RegistryPath -Name 'ShortcutsJson_LastKnownGood' -Value $oldJson -PropertyType String -Force | Out-Null
    }

    New-ItemProperty -Path $script:RegistryPath -Name $script:ShortcutsValueName -Value ([string]$pending) -PropertyType String -Force | Out-Null
    Remove-ItemProperty -Path $script:RegistryPath -Name $pendingName -ErrorAction SilentlyContinue
}

function Initialize-ShortcutStore {
    $script:ShortcutStore = @()

    try {
        $currentJson = Read-CurrentShortcutJson

        if ($null -eq $currentJson) {
            $script:ShortcutStore = @(Normalize-ShortcutCollection (Get-DefaultShortcuts))
            Save-ShortcutStore
            return
        }

        $currentItems = @()
        $currentParseOk = $false
        $currentSchema = ''

        try {
            $parsedCurrent = $currentJson | ConvertFrom-Json -ErrorAction Stop
            $currentSchema = [string](Get-SafePropertyValue $parsedCurrent 'Schema' '')
            $currentItems = @(Convert-JsonToShortcutItems $currentJson)
            $currentParseOk = $true
        } catch {
            $currentParseOk = $false
        }

        $usefulCurrent = @(
            $currentItems | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.Target)
            }
        )

        # If current storage contains usable shortcuts, keep them.
        if ($currentParseOk -and $usefulCurrent.Count -gt 0) {
            if ($currentSchema -eq 'LaviControlCenter.Shortcuts') {
                Backup-ShortcutJson $currentJson 'BeforeAppRenameMigration'
            }

            $script:ShortcutStore = @($currentItems)
            Save-ShortcutStore
            return
        }

        # Important recovery path:
        # v2.4 could convert the old schema to an empty collection after rename.
        # If current storage is empty, do NOT immediately accept it. First check
        # transactional LastKnownGood and timestamped backups.
        $recovered = @(Get-BestRecoverableShortcutItems)
        $usefulRecovered = @(
            $recovered | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.Target)
            }
        )

        if ($usefulRecovered.Count -gt 0) {
            Backup-ShortcutJson $currentJson 'BeforeAutoRecovery'
            $script:ShortcutStore = @(Normalize-ShortcutCollection $recovered)
            Save-ShortcutStore

            Show-Info (
                "Shortcut lama berhasil dipulihkan otomatis.`n`n" +
                "Jumlah shortcut: $($script:ShortcutStore.Count)"
            ) 'Pemulihan Shortcut'
            return
        }

        # If the current data is a genuinely valid empty current-schema store,
        # preserve it. This supports users who intentionally deleted everything.
        if ($currentParseOk -and
            $currentItems.Count -eq 0 -and
            $currentSchema -eq 'WindowsShortcutControl.Shortcuts') {

            $script:ShortcutStore = @()
            return
        }

        # No usable current or backup data: create defaults only as final fallback.
        Backup-ShortcutJson $currentJson 'Unrecoverable'
        $script:ShortcutStore = @(Normalize-ShortcutCollection (Get-DefaultShortcuts))
        Save-ShortcutStore

        Show-Info (
            'Data shortcut lama tidak dapat dipulihkan. Shortcut default dibuat kembali.'
        ) 'Pemulihan Shortcut'
    }
    catch {
        # Last defensive fallback: do not destroy existing Registry data again.
        try {
            $recovered = @(Get-BestRecoverableShortcutItems)
            if ($recovered.Count -gt 0) {
                $script:ShortcutStore = @(Normalize-ShortcutCollection $recovered)
                Save-ShortcutStore
                return
            }
        } catch {}

        $script:ShortcutStore = @(Normalize-ShortcutCollection (Get-DefaultShortcuts))
        try { Save-ShortcutStore } catch {}
        Show-Error $_.Exception.Message 'Pemulihan Data Shortcut'
    }
}


function Load-Shortcuts {
    return $script:ShortcutStore
}

function Save-Shortcuts([object[]]$Items) {
    $script:ShortcutStore = @(Normalize-ShortcutCollection @($Items))
    Save-ShortcutStore
}

function Get-AppSelfPath {
    $selfPath = [Environment]::GetEnvironmentVariable('LAVI_CONTROL_CENTER_SELF')
    if (-not [string]::IsNullOrWhiteSpace($selfPath)) { return $selfPath }
    if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
    return ''
}

function Test-ShortcutTarget([object]$Item) {
    if ($null -eq $Item) { return $false }

    try {
        $type = [string](Get-SafePropertyValue $Item 'Type' '')
        $rawTarget = [string](Get-SafePropertyValue $Item 'Target' '')

        # Important: Test-Path -LiteralPath throws when passed an empty string
        # on several PowerShell/Windows versions. Invalid shortcut data must
        # never be allowed to crash the whole application.
        if ([string]::IsNullOrWhiteSpace($rawTarget)) {
            return $false
        }

        $target = [Environment]::ExpandEnvironmentVariables($rawTarget)
        if ([string]::IsNullOrWhiteSpace($target)) {
            return $false
        }

        switch ($type) {
            'Folder' {
                try { return [bool](Test-Path -LiteralPath $target -PathType Container -ErrorAction Stop) }
                catch { return $false }
            }

            'File' {
                try { return [bool](Test-Path -LiteralPath $target -PathType Leaf -ErrorAction Stop) }
                catch { return $false }
            }

            'App' {
                try {
                    if (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction Stop) {
                        return $true
                    }
                } catch {}

                try {
                    return ($null -ne (Get-Command $target -ErrorAction Stop))
                } catch {
                    return $false
                }
            }

            'URL' {
                return ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*://')
            }

            'PowerShell' {
                return (-not [string]::IsNullOrWhiteSpace($target))
            }

            default {
                return $false
            }
        }
    } catch {
        # Target validation is informational only. It must never terminate UI.
        return $false
    }
}

function Export-ShortcutData {
    try {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Title = 'Export Shortcut Windows Shortcut Control'
        $dlg.Filter = 'Windows Shortcut Backup (*.json)|*.json|JSON (*.json)|*.json'
        $dlg.FileName = 'Windows-Shortcut-Control-Shortcuts-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'
        if (-not $dlg.ShowDialog($window)) { return }

        $items = @()
        foreach ($i in @($script:ShortcutStore)) {
            if ($null -eq $i) { continue }

            $items += [pscustomobject][ordered]@{
                Id         = [string]$i.Id
                Name       = [string]$i.Name
                Type       = [string]$i.Type
                Target     = [string]$i.Target
                Icon       = [string]$i.Icon
                Category   = [string]$i.Category
                Favorite   = [bool]$i.Favorite
                Pinned     = [bool]$i.Pinned
                OpenCount  = [int]$i.OpenCount
                LastOpened = [string]$i.LastOpened
            }
        }

        $obj = [pscustomobject][ordered]@{
            Schema     = 'WindowsShortcutControl.Shortcuts'
            Version    = 4
            AppVersion = $script:AppVersion
            ExportedAt = (Get-Date).ToString('o')
            Items      = $items
        }

        [IO.File]::WriteAllText(
            $dlg.FileName,
            (ConvertTo-Json $obj -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )

        Set-Status "Export berhasil: $($dlg.FileName)"
        Show-Info 'Shortcut berhasil diekspor lengkap termasuk Favorite, Pin, Open Count, dan Recent.' 'Export'
    } catch {
        Show-Error $_.Exception.Message 'Export Shortcut'
    }
}

function Import-ShortcutData {
    try {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Import Shortcut Windows Shortcut Control'
        $dlg.Filter = 'Lavi Shortcut Backup (*.json)|*.json|JSON (*.json)|*.json|Semua File (*.*)|*.*'
        if (-not $dlg.ShowDialog($window)) { return }
        $json = [IO.File]::ReadAllText($dlg.FileName)
        $items = @(Convert-JsonToShortcutItems $json)
        if ($items.Count -eq 0) { throw 'File tidak berisi shortcut yang valid.' }

        $choice = [System.Windows.MessageBox]::Show("Ditemukan $($items.Count) shortcut.`n`nYES = Gabungkan dengan data sekarang`nNO = Ganti seluruh data`nCANCEL = Batal", 'Import Shortcut', 'YesNoCancel', 'Question')
        if ($choice -eq 'Cancel') { return }

        if ($choice -eq 'Yes') {
            $merged = @($script:ShortcutStore)
            foreach ($incoming in $items) {
                $incoming.Id = [guid]::NewGuid().ToString('D')
                $merged += $incoming
            }
            $script:ShortcutStore = @(Normalize-ShortcutCollection $merged)
        } else {
            $script:ShortcutStore = @(Normalize-ShortcutCollection $items)
        }
        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status "Import berhasil: $($items.Count) shortcut."
    } catch { Show-Error $_.Exception.Message 'Import Shortcut' }
}

function Get-SerializableShortcutItems {
    $items = @()

    foreach ($i in @($script:ShortcutStore)) {
        if ($null -eq $i) { continue }

        $items += [pscustomobject][ordered]@{
            Id         = [string]$i.Id
            Name       = [string]$i.Name
            Type       = [string]$i.Type
            Target     = [string]$i.Target
            Icon       = [string]$i.Icon
            Category   = [string]$i.Category
            Favorite   = [bool]$i.Favorite
            Pinned     = [bool]$i.Pinned
            OpenCount  = [int]$i.OpenCount
            LastOpened = [string]$i.LastOpened
        }
    }

    return @($items)
}

function Export-AppConfiguration {
    try {
        if ($null -eq $script:AppSettings) {
            Load-AppSettings
        }

        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Title = 'Backup Konfigurasi Windows Shortcut Control'
        $dlg.Filter = 'Windows Shortcut Control Backup (*.wsc.json)|*.wsc.json|JSON (*.json)|*.json'
        $dlg.FileName = 'Windows-Shortcut-Control-FullBackup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wsc.json'

        if (-not $dlg.ShowDialog($window)) { return }

        $payload = [pscustomobject][ordered]@{
            Schema     = 'WindowsShortcutControl.Configuration'
            Version    = 1
            AppVersion = $script:AppVersion
            ExportedAt = (Get-Date).ToString('o')
            Settings   = (Normalize-AppSettings $script:AppSettings)
            Shortcuts  = @(Get-SerializableShortcutItems)
        }

        [IO.File]::WriteAllText(
            $dlg.FileName,
            (ConvertTo-Json $payload -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        Set-Status 'Backup konfigurasi lengkap berhasil dibuat.'
        Show-Info (
            "Backup konfigurasi lengkap berhasil dibuat.`n`n" +
            "Shortcut: $(@($script:ShortcutStore).Count)`n" +
            "Settings: termasuk`n`n" +
            $dlg.FileName
        ) 'Backup Konfigurasi'
    }
    catch {
        Show-Error $_.Exception.Message 'Backup Konfigurasi'
    }
}

function Import-AppConfiguration {
    try {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Restore Konfigurasi Windows Shortcut Control'
        $dlg.Filter = 'Windows Shortcut Control Backup (*.wsc.json;*.json)|*.wsc.json;*.json|Semua File (*.*)|*.*'

        if (-not $dlg.ShowDialog($window)) { return }

        $parsed = ([IO.File]::ReadAllText($dlg.FileName)) | ConvertFrom-Json -ErrorAction Stop

        $schema = [string](Get-SafePropertyValue $parsed 'Schema' '')
        if ($schema -ne 'WindowsShortcutControl.Configuration') {
            throw 'File bukan backup konfigurasi lengkap Windows Shortcut Control.'
        }

        $incoming = @(
            Normalize-ShortcutCollection @(
                Get-SafePropertyValue $parsed 'Shortcuts' @()
            )
        )
        if ($incoming.Count -eq 0) {
            throw 'Backup tidak berisi shortcut yang valid.'
        }

        $settings = Normalize-AppSettings (Get-SafePropertyValue $parsed 'Settings' $null)

        $msg = (
            "Restore konfigurasi lengkap?`n`n" +
            "Shortcut backup : $($incoming.Count)`n" +
            "Shortcut saat ini: $(@($script:ShortcutStore).Count)`n`n" +
            "Shortcut dan Settings saat ini akan diganti.`n" +
            "Backup Registry dibuat otomatis sebelum restore."
        )

        if (-not (Ask-Confirm $msg 'Restore Konfigurasi')) { return }

        $current = Read-CurrentShortcutJson
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            Backup-ShortcutJson $current 'BeforeFullConfigRestore'
        }

        $script:ShortcutStore = @($incoming)
        $script:AppSettings = $settings

        Save-ShortcutStore
        Save-AppSettings

        $startupOk = Set-StartupRegistration ([bool]$script:AppSettings.RunAtStartup)
        if (-not $startupOk -and [bool]$script:AppSettings.RunAtStartup) {
            $script:AppSettings.RunAtStartup = $false
            Save-AppSettings
        }

        [void](Initialize-SystemTray)
        Apply-GlobalHotkeySetting
        Apply-SettingsToUI
        Refresh-ShortcutViews
        Refresh-ToolViews
        Refresh-DashboardViews

        Set-Status 'Konfigurasi lengkap berhasil dipulihkan.'
        Show-Info "Restore konfigurasi berhasil.`nShortcut dipulihkan: $($script:ShortcutStore.Count)" 'Restore Konfigurasi'
    }
    catch {
        Show-Error $_.Exception.Message 'Restore Konfigurasi'
    }
}

function Get-SelfDiagnosticResults {
    $results = New-Object System.Collections.Generic.List[object]

    $add = {
        param([string]$Status,[string]$Check,[string]$Detail)
        [void]$results.Add([pscustomobject]@{
            Status = $Status
            Check  = $Check
            Detail = $Detail
        })
    }

    try {
        $self = Get-AppSelfPath
        if (-not [string]::IsNullOrWhiteSpace($self) -and
            (Test-Path -LiteralPath $self -PathType Leaf -ErrorAction SilentlyContinue)) {
            & $add 'OK' 'Application File' $self
        } else {
            & $add 'WARN' 'Application File' 'File aplikasi tidak terdeteksi.'
        }
    } catch {
        & $add 'FAIL' 'Application File' $_.Exception.Message
    }

    try {
        Ensure-RegistryPath
        & $add 'OK' 'Registry Storage' $script:RegistryPath
    } catch {
        & $add 'FAIL' 'Registry Storage' $_.Exception.Message
    }

    try {
        $json = Read-CurrentShortcutJson
        if ([string]::IsNullOrWhiteSpace($json)) {
            & $add 'WARN' 'Shortcut JSON' 'Current JSON kosong.'
        } else {
            $parsedItems = @(Convert-JsonToShortcutItems $json)
            & $add 'OK' 'Shortcut JSON' "$($parsedItems.Count) shortcut valid."
        }
    } catch {
        & $add 'FAIL' 'Shortcut JSON' $_.Exception.Message
    }

    try {
        $lkg = @(Get-LastKnownGoodShortcutItems)
        if ($lkg.Count -gt 0) {
            & $add 'OK' 'Last Known Good' "$($lkg.Count) shortcut tersedia."
        } else {
            & $add 'INFO' 'Last Known Good' 'Belum tersedia atau kosong.'
        }
    } catch {
        & $add 'WARN' 'Last Known Good' $_.Exception.Message
    }

    try {
        if ($null -eq $script:AppSettings) { Load-AppSettings }
        $st = Normalize-AppSettings $script:AppSettings
        & $add 'OK' 'Settings' ("Startup={0}, Close={1}, Hotkey={2}" -f `
            $st.RunAtStartup,$st.CloseBehavior,$st.GlobalHotkey)
    } catch {
        & $add 'FAIL' 'Settings' $_.Exception.Message
    }

    try {
        Initialize-ToolCatalog
        & $add 'OK' 'Windows Tools' "$(@($script:ToolCatalog).Count) tool terdaftar."
    } catch {
        & $add 'FAIL' 'Windows Tools' $_.Exception.Message
    }

    try {
        if ($null -ne $script:TrayIcon -and $script:TrayIcon.Visible) {
            & $add 'OK' 'System Tray' 'NotifyIcon aktif.'
        } else {
            & $add 'WARN' 'System Tray' 'Tray icon belum aktif.'
        }
    } catch {
        & $add 'WARN' 'System Tray' $_.Exception.Message
    }

    try {
        if ($null -ne $script:AppSettings -and [bool]$script:AppSettings.GlobalHotkey) {
            if ($script:GlobalHotkeyRegistered) {
                & $add 'OK' 'Global Hotkey' 'Ctrl + Alt + Space terdaftar.'
            } else {
                & $add 'WARN' 'Global Hotkey' 'Diaktifkan tetapi belum/gagal didaftarkan.'
            }
        } else {
            & $add 'INFO' 'Global Hotkey' 'Dinonaktifkan.'
        }
    } catch {
        & $add 'WARN' 'Global Hotkey' $_.Exception.Message
    }

    try {
        Initialize-BackgroundRunspacePool
        if ($null -ne $script:BackgroundRunspacePool) {
            & $add 'OK' 'Background Runspace' 'RunspacePool aktif.'
        } else {
            & $add 'FAIL' 'Background Runspace' 'RunspacePool tidak tersedia.'
        }
    } catch {
        & $add 'FAIL' 'Background Runspace' $_.Exception.Message
    }

    try {
        if ($null -ne $script:AppSettings -and [bool]$script:AppSettings.RunAtStartup) {
            $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $reg = Get-ItemProperty -Path $runPath -Name 'WindowsShortcutControl' -ErrorAction Stop
            $value = [string]$reg.PSObject.Properties['WindowsShortcutControl'].Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                & $add 'OK' 'Windows Startup' $value
            } else {
                & $add 'WARN' 'Windows Startup' 'Value startup kosong.'
            }
        } else {
            & $add 'INFO' 'Windows Startup' 'Dinonaktifkan.'
        }
    } catch {
        & $add 'WARN' 'Windows Startup' $_.Exception.Message
    }

    return @($results.ToArray())
}

function Show-SelfDiagnostics {
    try {
        $items = @(Get-SelfDiagnosticResults)

        $okCount = @($items | Where-Object { $_.Status -eq 'OK' }).Count
        $warnCount = @($items | Where-Object { $_.Status -in @('WARN','INFO') }).Count
        $failCount = @($items | Where-Object { $_.Status -eq 'FAIL' }).Count

        [xml]$diagXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Self Diagnostics"
        Width="720" Height="500"
        MinWidth="620" MinHeight="420"
        WindowStartupLocation="CenterOwner"
        Background="#F6F8FC"
        Foreground="#172033"
        FontFamily="Segoe UI"
        FontSize="12"
        ShowInTaskbar="False">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel>
            <TextBlock Text="Self Diagnostics" FontSize="22" FontWeight="Bold"/>
            <TextBlock Text="Pemeriksaan cepat komponen utama Windows Shortcut Control."
                       Foreground="#667085" Margin="0,4,0,0"/>
        </StackPanel>

        <TextBlock x:Name="DiagSummary" Grid.Row="1"
                   Foreground="#475467" Margin="0,14,0,10"/>

        <DataGrid x:Name="DiagGrid" Grid.Row="2"
                  AutoGenerateColumns="False"
                  IsReadOnly="True"
                  CanUserAddRows="False"
                  HeadersVisibility="Column"
                  GridLinesVisibility="Horizontal"
                  Background="#FFFFFF"
                  BorderBrush="#E4E7EC"
                  BorderThickness="1"
                  RowHeaderWidth="0">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="75"/>
                <DataGridTextColumn Header="Check" Binding="{Binding Check}" Width="155"/>
                <DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>

        <StackPanel Grid.Row="3" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="CopyDiagBtn" Content="Copy Report"
                    Padding="14,7" Margin="0,0,8,0"/>
            <Button x:Name="CloseDiagBtn" Content="Tutup"
                    Padding="14,7"/>
        </StackPanel>
    </Grid>
</Window>
'@

        $r = New-Object System.Xml.XmlNodeReader $diagXaml
        $diagWindow = [Windows.Markup.XamlReader]::Load($r)
        $diagWindow.Owner = $window

        $grid = $diagWindow.FindName('DiagGrid')
        $summary = $diagWindow.FindName('DiagSummary')
        $copy = $diagWindow.FindName('CopyDiagBtn')
        $close = $diagWindow.FindName('CloseDiagBtn')

        if ((Get-AppLanguage) -eq 'en') {
            $summary.Text = "OK: $okCount    Warning/Info: $warnCount    Fail: $failCount"
        } else {
            $summary.Text = "OK: $okCount    Peringatan/Info: $warnCount    Gagal: $failCount"
        }
        $grid.ItemsSource = $items
        try {
            $grid.Columns[0].Header = 'Status'
            $grid.Columns[1].Header = (L 'Pemeriksaan' 'Check')
            $grid.Columns[2].Header = 'Detail'
        } catch {}
$diagState = [pscustomobject]@{ Dialog = $diagWindow }
        $diagWindow.Tag = $diagState
        $close.Tag = $diagState
        Apply-LanguageToElement $diagWindow

        $close.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -ne $s -and $null -ne $s.Dialog) { $s.Dialog.Close() }
            } catch {}
        })

        [void]$diagWindow.ShowDialog()
    }
    catch {
        Show-Error $_.Exception.Message 'Self Diagnostics'
    }
}

function Restore-LastKnownGood {
    try {
        $reg = Get-ItemProperty -Path $script:RegistryPath -Name 'ShortcutsJson_LastKnownGood' -ErrorAction Stop
        $json = [string]$reg.PSObject.Properties['ShortcutsJson_LastKnownGood'].Value
        $items = @(Convert-JsonToShortcutItems $json)
        if ($items.Count -eq 0) { throw 'Backup LastKnownGood kosong.' }
        if (-not (Ask-Confirm "Pulihkan $($items.Count) shortcut dari Last Known Good?`nData saat ini akan diganti." 'Restore')) { return }
        $script:ShortcutStore = @(Normalize-ShortcutCollection $items)
        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status 'Last Known Good berhasil dipulihkan.'
    } catch { Show-Error ('Backup LastKnownGood belum tersedia atau rusak.`n' + $_.Exception.Message) 'Restore' }
}

function Reset-ShortcutDefaults {
    if (-not (Ask-Confirm 'Reset semua shortcut ke bawaan? Data shortcut saat ini akan diganti.' 'Reset Shortcut')) { return }
    try {
        $old = Read-CurrentShortcutJson
        if (-not [string]::IsNullOrWhiteSpace($old)) { Backup-ShortcutJson $old 'ManualReset' }
        $script:ShortcutStore = @(Normalize-ShortcutCollection (Get-DefaultShortcuts))
        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status 'Shortcut dikembalikan ke default.'
    } catch { Show-Error $_.Exception.Message 'Reset Shortcut' }
}

function Create-DesktopAppShortcut {
    try {
        $self = Get-AppSelfPath
        if ([string]::IsNullOrWhiteSpace($self) -or -not (Test-Path -LiteralPath $self)) { throw 'Lokasi file aplikasi tidak ditemukan.' }
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desktop 'Windows Shortcut Control.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = $self
        $sc.WorkingDirectory = Split-Path -Parent $self
        $sc.Description = 'Windows Shortcut Control'
        $sc.Save()
        Show-Info "Shortcut Desktop dibuat:`n$lnk" 'Desktop Shortcut'
    } catch { Show-Error $_.Exception.Message 'Desktop Shortcut' }
}

function Open-AppRegistry {
    try {
        Start-Process reg.exe -ArgumentList 'add','HKCU\Software\WindowsShortcutControl','/f' -WindowStyle Hidden -Wait
        Start-Process regedit.exe
        Set-ClipboardText 'HKEY_CURRENT_USER\Software\LaviControlCenter'
        Set-Status 'Registry path disalin. Registry Editor dibuka.'
    } catch { Show-Error $_.Exception.Message 'Registry' }
}

function Open-TerminalForShortcut([object]$Item) {
    try {
        if ($null -eq $Item) { throw 'Data shortcut tidak valid.' }

        $rawTarget = [string](Get-SafePropertyValue $Item 'Target' '')
        $type = [string](Get-SafePropertyValue $Item 'Type' '')

        if ([string]::IsNullOrWhiteSpace($rawTarget)) {
            throw 'Target shortcut kosong.'
        }

        $target = [Environment]::ExpandEnvironmentVariables($rawTarget)
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw 'Target shortcut tidak valid.'
        }

        $dir = $target

        if ($type -in @('File','App')) {
            try { $dir = Split-Path -Parent $target } catch { $dir = '' }
        }

        if ([string]::IsNullOrWhiteSpace($dir) -or
            -not (Test-Path -LiteralPath $dir -PathType Container -ErrorAction SilentlyContinue)) {
            throw 'Folder target tidak ditemukan.'
        }

        Start-Process powershell.exe -WorkingDirectory $dir
    } catch {
        Show-Error $_.Exception.Message 'Terminal'
    }
}

function Run-ShortcutAsAdmin([object]$Item) {
    try {
        if ($null -eq $Item) { throw 'Data shortcut tidak valid.' }

        $type = [string](Get-SafePropertyValue $Item 'Type' '')
        $rawTarget = [string](Get-SafePropertyValue $Item 'Target' '')

        if ([string]::IsNullOrWhiteSpace($rawTarget)) {
            throw 'Target shortcut kosong.'
        }

        $target = [Environment]::ExpandEnvironmentVariables($rawTarget)
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw 'Target shortcut tidak valid.'
        }

        switch ($type) {
            'PowerShell' {
                Start-Process powershell.exe -Verb RunAs `
                    -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$target
            }

            'App' {
                if (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction SilentlyContinue) {
                    Start-Process -FilePath $target -Verb RunAs
                } else {
                    $cmd = Get-Command $target -ErrorAction SilentlyContinue
                    if ($null -eq $cmd) { throw "Aplikasi tidak ditemukan:`n$target" }
                    Start-Process -FilePath $target -Verb RunAs
                }
            }

            'File' {
                if (-not (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction SilentlyContinue)) {
                    throw "File tidak ditemukan:`n$target"
                }
                Start-Process -FilePath $target -Verb RunAs
            }

            default {
                throw 'Run as Administrator hanya tersedia untuk App, File, dan PowerShell.'
            }
        }
    } catch {
        Show-Error $_.Exception.Message 'Run as Administrator'
    }
}

function Duplicate-Shortcut([object]$Item) {
    try {
        $copy = [pscustomobject][ordered]@{
            Id         = [guid]::NewGuid().ToString('D')
            Name       = ([string]$Item.Name + ' - Copy')
            Type       = [string]$Item.Type
            Target     = [string]$Item.Target
            Icon       = [string]$Item.Icon
            Category   = [string]$Item.Category
            Favorite   = $false
            Pinned     = $false
            OpenCount  = 0
            LastOpened = ''
        }
        $script:ShortcutStore = @($script:ShortcutStore) + @($copy)
        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status "Shortcut '$($Item.Name)' diduplikasi."
    } catch {
        Show-Error $_.Exception.Message 'Duplicate Shortcut'
    }
}

function Move-Shortcut([string]$Id, [int]$Direction) {
    try {
        $arr = @($script:ShortcutStore)
        $index = -1
        for ($i=0; $i -lt $arr.Count; $i++) { if ([string]$arr[$i].Id -eq $Id) { $index=$i; break } }
        if ($index -lt 0) { throw 'Shortcut tidak ditemukan.' }
        $newIndex = $index + $Direction
        if ($newIndex -lt 0 -or $newIndex -ge $arr.Count) { return }
        $tmp=$arr[$index]; $arr[$index]=$arr[$newIndex]; $arr[$newIndex]=$tmp
        $script:ShortcutStore=@($arr); Save-ShortcutStore; Refresh-ShortcutViews
    } catch { Show-Error $_.Exception.Message 'Urutan Shortcut' }
}

function Show-Error([string]$Message, [string]$Title='Error') {
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
}

function Show-Info([string]$Message, [string]$Title=$script:AppName) {
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Information') | Out-Null
}

function Ask-Confirm([string]$Message, [string]$Title='Konfirmasi') {
    return ([System.Windows.MessageBox]::Show($Message, $Title, 'YesNo', 'Question') -eq 'Yes')
}

function Set-ClipboardText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    [System.Windows.Clipboard]::SetText($Text)
}

function Register-ShortcutOpen([object]$Item) {
    try {
        if ($null -eq $Item) { return }

        $count = 0
        try { $count = [int]$Item.OpenCount } catch { $count = 0 }
        if ($count -lt 0) { $count = 0 }

        $Item.OpenCount = $count + 1
        $Item.LastOpened = (Get-Date).ToString('o')

        Save-ShortcutStore
        Refresh-DashboardViews
    } catch {
        # Usage history must never block opening the shortcut.
        Set-Status ('Shortcut dibuka, tetapi history gagal disimpan: ' + $_.Exception.Message)
    }
}

function Toggle-ShortcutFlag([string]$Id, [ValidateSet('Favorite','Pinned')][string]$Flag) {
    try {
        $item = Get-ShortcutById $Id
        if ($null -eq $item) { throw 'Shortcut tidak ditemukan.' }

        if ($Flag -eq 'Favorite') {
            $item.Favorite = -not [bool]$item.Favorite
            $message = if ($item.Favorite) {
                "'$($item.Name)' ditambahkan ke Favorit."
            } else {
                "'$($item.Name)' dihapus dari Favorit."
            }
        } else {
            $item.Pinned = -not [bool]$item.Pinned
            $message = if ($item.Pinned) {
                "'$($item.Name)' dipin ke Dashboard."
            } else {
                "'$($item.Name)' dilepas dari Dashboard."
            }
        }

        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status $message
    } catch {
        Show-Error $_.Exception.Message 'Shortcut'
    }
}

function Open-Target([pscustomobject]$Item) {
    try {
        if ($null -eq $Item) { throw 'Data shortcut tidak valid.' }

        $type = [string](Get-SafePropertyValue $Item 'Type' '')
        $rawTarget = [string](Get-SafePropertyValue $Item 'Target' '')
        $name = [string](Get-SafePropertyValue $Item 'Name' 'Shortcut')

        if ([string]::IsNullOrWhiteSpace($rawTarget)) {
            throw "Target shortcut '$name' kosong. Gunakan Edit Shortcut untuk memperbaikinya."
        }

        $target = [Environment]::ExpandEnvironmentVariables($rawTarget)
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw "Target shortcut '$name' tidak valid."
        }

        switch ($type) {
            'Folder' {
                if (-not (Test-Path -LiteralPath $target -PathType Container -ErrorAction SilentlyContinue)) {
                    throw "Folder tidak ditemukan:`n$target"
                }
                Start-Process explorer.exe -ArgumentList "`"$target`""
            }

            'File' {
                if (-not (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction SilentlyContinue)) {
                    throw "File tidak ditemukan:`n$target"
                }
                Start-Process -FilePath $target
            }

            'App' {
                if (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction SilentlyContinue) {
                    Start-Process -FilePath $target
                } else {
                    $cmd = Get-Command $target -ErrorAction SilentlyContinue
                    if ($null -eq $cmd) {
                        throw "Aplikasi tidak ditemukan:`n$target"
                    }
                    Start-Process -FilePath $target
                }
            }

            'URL' {
                if ($target -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                    throw "URL tidak valid:`n$target"
                }
                Start-Process $target
            }

            'PowerShell' {
                Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$target
            }

            default {
                throw "Tipe shortcut tidak dikenal: $type"
            }
        }

        Register-ShortcutOpen $Item
        Set-Status "Membuka: $name"
    } catch {
        Show-Error $_.Exception.Message 'Buka Shortcut'
        Set-Status 'Gagal membuka target.'
    }
}

function Open-ParentFolder([pscustomobject]$Item) {
    try {
        if ($null -eq $Item) { throw 'Data shortcut tidak valid.' }

        $type = [string](Get-SafePropertyValue $Item 'Type' '')
        $rawTarget = [string](Get-SafePropertyValue $Item 'Target' '')

        if ([string]::IsNullOrWhiteSpace($rawTarget)) {
            throw 'Target shortcut kosong.'
        }

        $target = [Environment]::ExpandEnvironmentVariables($rawTarget)
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw 'Target shortcut tidak valid.'
        }

        switch ($type) {
            'Folder' {
                if (-not (Test-Path -LiteralPath $target -PathType Container -ErrorAction SilentlyContinue)) {
                    throw 'Folder tidak ditemukan.'
                }
                Start-Process explorer.exe -ArgumentList "`"$target`""
            }

            'File' {
                if (-not (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction SilentlyContinue)) {
                    throw 'File tidak ditemukan.'
                }
                Start-Process explorer.exe -ArgumentList "/select,`"$target`""
            }

            'App' {
                if (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction SilentlyContinue) {
                    Start-Process explorer.exe -ArgumentList "/select,`"$target`""
                } else {
                    Set-ClipboardText $target
                    Set-Status 'Target aplikasi disalin ke Clipboard.'
                }
            }

            default {
                Set-ClipboardText $target
                Set-Status 'Target disalin ke Clipboard.'
            }
        }
    } catch {
        Show-Error $_.Exception.Message 'Buka Lokasi'
    }
}

function Get-SystemSnapshot {
    try {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | Sort-Object DeviceID
        } catch {
            $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
            $cpu = Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
            $disk = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | Sort-Object DeviceID
        }

        $ramTotal = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)
        $ramFree = [math]::Round([double]$os.FreePhysicalMemory * 1KB / 1GB, 1)
        $ramUsed = [math]::Round($ramTotal - $ramFree, 1)
        $ramPct = if ($ramTotal -gt 0) { [math]::Round(($ramUsed / $ramTotal) * 100) } else { 0 }

        $lastBoot = $os.LastBootUpTime
        if ($lastBoot -is [string]) {
            try { $lastBoot = [Management.ManagementDateTimeConverter]::ToDateTime($lastBoot) } catch {}
        }
        $uptime = (Get-Date) - [datetime]$lastBoot
        $uptimeText = '{0} hari {1} jam {2} menit' -f [int]$uptime.TotalDays, $uptime.Hours, $uptime.Minutes

        [pscustomobject]@{
            Computer = $env:COMPUTERNAME
            User = $env:USERNAME
            Windows = [string]$os.Caption
            Version = [string]$os.Version
            CPU = [string]$cpu.Name
            RAM = "$ramUsed GB / $ramTotal GB ($ramPct%)"
            Uptime = $uptimeText
            Disks = @($disk | ForEach-Object {
                $total = [math]::Round([double]$_.Size / 1GB, 1)
                $free = [math]::Round([double]$_.FreeSpace / 1GB, 1)
                "$($_.DeviceID)    $free GB bebas / $total GB"
            })
        }
    } catch {
        [pscustomobject]@{
            Computer=$env:COMPUTERNAME; User=$env:USERNAME; Windows='Tidak tersedia';
            Version='-'; CPU='-'; RAM='-'; Uptime='-'; Disks=@('-')
        }
    }
}

function Start-SafeProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$FallbackFilePath = '',
        [string[]]$FallbackArgumentList = @()
    )
    try {
        if ($ArgumentList.Count -gt 0) {
            Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -ErrorAction Stop
        } else {
            Start-Process -FilePath $FilePath -ErrorAction Stop
        }
        Set-Status "Membuka: $FilePath"
        return
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($FallbackFilePath)) {
            try {
                if ($FallbackArgumentList.Count -gt 0) {
                    Start-Process -FilePath $FallbackFilePath -ArgumentList $FallbackArgumentList -ErrorAction Stop
                } else {
                    Start-Process -FilePath $FallbackFilePath -ErrorAction Stop
                }
                Set-Status "Membuka alternatif: $FallbackFilePath"
                return
            } catch {}
        }
        Show-Error ("Tidak dapat membuka:`n{0}`n`n{1}" -f $FilePath, $_.Exception.Message)
        Set-Status 'Gagal menjalankan Windows Tool.'
    }
}

function Get-TypeBadge([string]$Type) {
    switch ($Type) {
        'Folder'     { return 'DIR' }
        'File'       { return 'FILE' }
        'App'        { return 'APP' }
        'URL'        { return 'WEB' }
        'PowerShell' { return 'PS' }
        default      { return 'ITEM' }
    }
}

# ----------------------------
# XAML
# ----------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Shortcut Control"
        Width="980" Height="620"
        MinWidth="760" MinHeight="500"
        WindowStartupLocation="CenterScreen"
        Background="#F6F8FC"
        Foreground="#172033"
        FontFamily="Segoe UI"
        FontSize="13"
        ResizeMode="CanResize"
        AllowDrop="True"
        WindowStyle="None">
    <Window.Resources>
        <SolidColorBrush x:Key="Primary" Color="#2563EB"/>
        <SolidColorBrush x:Key="PrimaryHover" Color="#1D4ED8"/>
        <SolidColorBrush x:Key="TextMain" Color="#172033"/>
        <SolidColorBrush x:Key="TextMuted" Color="#667085"/>
        <SolidColorBrush x:Key="Border" Color="#E2E8F0"/>
        <SolidColorBrush x:Key="Card" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="Canvas" Color="#F6F8FC"/>

        <Style x:Key="WindowButton" TargetType="Button">
            <Setter Property="Width" Value="44"/>
            <Setter Property="Height" Value="44"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#475467"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ControlBg" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ControlBg" Property="Background" Value="#F2F4F7"/>
                                <Setter Property="Foreground" Value="#101828"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ControlBg" Property="Background" Value="#E4E7EC"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CloseWindowButton" TargetType="Button" BasedOn="{StaticResource WindowButton}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ControlBg" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ControlBg" Property="Background" Value="#FEE2E2"/>
                                <Setter Property="Foreground" Value="#B42318"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ControlBg" Property="Background" Value="#FECACA"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="NavButton" TargetType="Button">
            <Setter Property="Foreground" Value="#475467"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Padding" Value="11,0"/>
            <Setter Property="Margin" Value="6,2"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="NavBg"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8">
                            <Grid>
                                <Border x:Name="NavAccent"
                                        Width="3"
                                        Height="18"
                                        Background="Transparent"
                                        CornerRadius="2"
                                        HorizontalAlignment="Left"
                                        VerticalAlignment="Center"/>
                                <ContentPresenter Margin="{TemplateBinding Padding}"
                                                  HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                                  VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="NavBg" Property="Background" Value="#F8FAFC"/>
                                <Setter TargetName="NavAccent" Property="Background" Value="#2563EB"/>
                                <Setter Property="Foreground" Value="#1D4ED8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="NavBg" Property="Background" Value="#EFF6FF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="UtilityNavButton" TargetType="Button" BasedOn="{StaticResource NavButton}">
            <Setter Property="Foreground" Value="#667085"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Height" Value="36"/>
        </Style>

        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="15,9"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1D4ED8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1E40AF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value=".45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#344054"/>
            <Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#F8FAFC"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#98A2B3"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ShortcutButton" TargetType="Button">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="BorderBrush" Value="#E4E7EC"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Width" Value="190"/>
            <Setter Property="Height" Value="108"/>
            <Setter Property="Margin" Value="6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="CardBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="11"
                                SnapsToDevicePixels="True">
                            <Grid>
                                <Border x:Name="HoverAccent"
                                        Width="3"
                                        Background="Transparent"
                                        CornerRadius="11,0,0,11"
                                        HorizontalAlignment="Left"/>
                                <ContentPresenter Margin="12"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CardBorder" Property="Background" Value="#FAFCFF"/>
                                <Setter TargetName="CardBorder" Property="BorderBrush" Value="#BFDBFE"/>
                                <Setter TargetName="HoverAccent" Property="Background" Value="#2563EB"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="CardBorder" Property="Background" Value="#EFF6FF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="CaretBrush" Value="#172033"/>
            <Setter Property="SelectionBrush" Value="#BFDBFE"/>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="Padding" Value="8,6"/>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="Padding" Value="8,6"/>
        </Style>

        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#172033"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Padding" Value="8"/>
        </Style>

        <Style x:Key="ModernSearchBox" TargetType="TextBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="CaretBrush" Value="#172033"/>
            <Setter Property="SelectionBrush" Value="#BFDBFE"/>
        </Style>

        <Style x:Key="ModernComboBox" TargetType="ComboBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#344054"/>
            <Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="9,6"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="MinHeight" Value="36"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style x:Key="SearchClearButton" TargetType="Button">
            <Setter Property="Width" Value="28"/>
            <Setter Property="Height" Value="28"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ClearBg"
                                Background="{TemplateBinding Background}"
                                CornerRadius="7">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ClearBg" Property="Background" Value="#F2F4F7"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ClearBg" Property="Background" Value="#E4E7EC"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Background="#F6F8FC">
        <Grid.RowDefinitions>
            <RowDefinition Height="48"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="30"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1" x:Name="TopBar">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="250"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="44"/>
                    <ColumnDefinition Width="44"/>
                    <ColumnDefinition Width="44"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="15,0">
                    <Border Background="#2563EB" CornerRadius="8" Width="28" Height="28">
                        <Viewbox Width="18" Height="18"
                                 HorizontalAlignment="Center"
                                 VerticalAlignment="Center">
                            <Canvas Width="24" Height="24">
                                <Path Data="M 4.5,5.5 L 17.5,5.5 L 17.5,15.5 L 4.5,15.5 Z
                                            M 11,5.5 L 11,15.5
                                            M 4.5,10.5 L 17.5,10.5
                                            M 13.5,19 L 20,12.5
                                            M 16.5,12.5 L 20,12.5 L 20,16"
                                      Stroke="#FFFFFF"
                                      StrokeThickness="1.65"
                                      StrokeStartLineCap="Round"
                                      StrokeEndLineCap="Round"
                                      StrokeLineJoin="Round"
                                      Fill="Transparent"/>
                            </Canvas>
                        </Viewbox>
                    </Border>
                    <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="Windows Shortcut Control" Foreground="#172033" FontWeight="SemiBold" FontSize="14"/>
                        <TextBlock Text="Launcher &amp; Windows workspace" Foreground="#98A2B3" FontSize="10"/>
                    </StackPanel>
                </StackPanel>

                <Border Grid.Column="1" Height="34" MaxWidth="430" Margin="12,0,14,0"
                        Background="#F8FAFC" BorderBrush="#E4E7EC" BorderThickness="1"
                        CornerRadius="9" VerticalAlignment="Center">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="34"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="34"/>
                        </Grid.ColumnDefinitions>
                        <Path Grid.Column="0"
                              Data="M 11,11 m -5,0 a 5,5 0 1,0 10,0 a 5,5 0 1,0 -10,0 M 14.5,14.5 L 19,19"
                              Stroke="#98A2B3" StrokeThickness="1.4"
                              Width="18" Height="18" Stretch="Uniform"
                              HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        <Grid Grid.Column="1">
                            <TextBox x:Name="TxtGlobalSearch"
                                     Style="{StaticResource ModernSearchBox}"
                                     ToolTip="Cari semua shortcut dan Windows Tools"/>
                            <TextBlock x:Name="TxtGlobalSearchHint"
                                       Text="Cari shortcut atau Windows Tools..."
                                       Foreground="#98A2B3" FontSize="12"
                                       IsHitTestVisible="False"
                                       VerticalAlignment="Center"/>
                        </Grid>
                        <Button x:Name="BtnClearGlobalSearch" Grid.Column="2"
                                Style="{StaticResource SearchClearButton}"
                                ToolTip="Bersihkan pencarian">
                            <Grid Width="14" Height="14">
                                <Ellipse Stroke="#98A2B3" StrokeThickness="1"
                                         Width="13" Height="13"
                                         HorizontalAlignment="Center"
                                         VerticalAlignment="Center"/>
                                <Path Data="M 4.5,4.5 L 9.5,9.5 M 9.5,4.5 L 4.5,9.5"
                                      Stroke="#667085" StrokeThickness="1.1"
                                      StrokeStartLineCap="Round"
                                      StrokeEndLineCap="Round"
                                      Width="14" Height="14" Stretch="None"/>
                            </Grid>
                        </Button>
                    </Grid>
                </Border>

                <Button x:Name="BtnMinimize" Grid.Column="2" Style="{StaticResource WindowButton}" ToolTip="Minimize">
                    <Path Data="M 2,8 L 12,8"
                          Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                          StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                          Width="14" Height="14" Stretch="None"/>
                </Button>

                <Button x:Name="BtnMaximize" Grid.Column="3" Style="{StaticResource WindowButton}" ToolTip="Maximize / Restore">
                    <Path Data="M 2.5,3.5 L 11.5,3.5 L 11.5,11 L 2.5,11 Z"
                          Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                          StrokeThickness="1.2" Width="14" Height="14" Stretch="None"/>
                </Button>

                <Button x:Name="BtnClose" Grid.Column="4" Style="{StaticResource CloseWindowButton}" ToolTip="Close">
                    <Path Data="M 3,3 L 11,11 M 11,3 L 3,11"
                          Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                          StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                          Width="14" Height="14" Stretch="None"/>
                </Button>
            </Grid>
        </Border>
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="205"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="#FFFFFF"
                    BorderBrush="#EAECF0" BorderThickness="0,0,1,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Margin="8,16,8,8">
                        <TextBlock Text="WORKSPACE"
                                   Foreground="#98A2B3"
                                   FontSize="9"
                                   FontWeight="Bold"
                                   Margin="14,0,0,8"/>

                        <Button x:Name="NavDashboard" Style="{StaticResource NavButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="24"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Path Data="M 3,3 L 8,3 L 8,8 L 3,8 Z M 10,3 L 15,3 L 15,8 L 10,8 Z M 3,10 L 8,10 L 8,15 L 3,15 Z M 10,10 L 15,10 L 15,15 L 10,15 Z"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.15"
                                      Width="16" Height="16" Stretch="Uniform"
                                      HorizontalAlignment="Left"/>
                                <TextBlock Grid.Column="1" Text="Dashboard" VerticalAlignment="Center"/>
                            </Grid>
                        </Button>

                        <Button x:Name="NavShortcuts" Style="{StaticResource NavButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="24"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Path Data="M 4,5 L 14,5 M 4,9 L 14,9 M 4,13 L 11,13 M 2,5 L 2.1,5 M 2,9 L 2.1,9 M 2,13 L 2.1,13"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.3"
                                      StrokeStartLineCap="Round"
                                      Width="16" Height="16" Stretch="Uniform"
                                      HorizontalAlignment="Left"/>
                                <TextBlock Grid.Column="1" Text="Shortcut" VerticalAlignment="Center"/>
                            </Grid>
                        </Button>

                        <Button x:Name="NavTools" Style="{StaticResource NavButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="24"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Path Data="M 8,2 A 6,6 0 1,0 8,14 A 6,6 0 1,0 8,2 M 8,5 A 3,3 0 1,0 8,11 A 3,3 0 1,0 8,5"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.1"
                                      Width="16" Height="16" Stretch="Uniform"
                                      HorizontalAlignment="Left"/>
                                <TextBlock Grid.Column="1" Text="Windows Tools" VerticalAlignment="Center"/>
                            </Grid>
                        </Button>

                        <Button x:Name="NavSystem" Style="{StaticResource NavButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="24"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Path Data="M 3,3 L 13,3 L 13,11 L 3,11 Z M 6,14 L 10,14 M 8,11 L 8,14"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.2"
                                      StrokeStartLineCap="Round"
                                      Width="16" Height="16" Stretch="Uniform"
                                      HorizontalAlignment="Left"/>
                                <TextBlock Grid.Column="1" Text="System Info" VerticalAlignment="Center"/>
                            </Grid>
                        </Button>

                        <Button x:Name="NavSettings" Style="{StaticResource NavButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="24"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Path Data="M 8,2.5 L 9.2,4.2 L 11.2,4 L 12,5.8 L 13.8,6.5 L 13.5,8.5 L 15,9.8 L 14,11.5 L 14.3,13.5 L 12.4,14.2 L 11.5,16 L 9.5,15.6 L 8,17 L 6.5,15.6 L 4.5,16 L 3.6,14.2 L 1.7,13.5 L 2,11.5 L 1,9.8 L 2.5,8.5 L 2.2,6.5 L 4,5.8 L 4.8,4 L 6.8,4.2 Z M 8,6 A 3,3 0 1,0 8,12 A 3,3 0 1,0 8,6"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.05"
                                      Width="16" Height="16" Stretch="Uniform"
                                      HorizontalAlignment="Left"/>
                                <TextBlock Grid.Column="1" Text="Settings" VerticalAlignment="Center"/>
                            </Grid>
                        </Button>
                    </StackPanel>

                    <StackPanel Grid.Row="2" Margin="8,8,8,14">
                        <Border Height="1" Background="#EAECF0" Margin="10,0,10,8"/>

                        <Button x:Name="BtnOpenScriptFolder" Style="{StaticResource UtilityNavButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="24"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Path Data="M 2,5 L 7,5 L 8.5,7 L 14,7 L 14,13 L 2,13 Z"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.15"
                                      Width="16" Height="16" Stretch="Uniform"
                                      HorizontalAlignment="Left"/>
                                <TextBlock Grid.Column="1" Text="Lokasi Aplikasi" VerticalAlignment="Center"/>
                            </Grid>
                        </Button>

                        <Button x:Name="BtnAbout" Style="{StaticResource UtilityNavButton}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="24"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Ellipse Width="14" Height="14"
                                         Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                         StrokeThickness="1.1"
                                         HorizontalAlignment="Left"/>
                                <TextBlock Text="i"
                                           Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                           FontSize="9"
                                           FontWeight="Bold"
                                           HorizontalAlignment="Left"
                                           Margin="5,0,0,0"
                                           VerticalAlignment="Center"/>
                                <TextBlock Grid.Column="1" Text="About" VerticalAlignment="Center"/>
                            </Grid>
                        </Button>
                    </StackPanel>
                </Grid>
            </Border>
            <Grid Grid.Column="1" Margin="22,18,22,16">

                <Grid x:Name="PageDashboard">
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <DockPanel LastChildFill="True" Margin="0,0,0,18">
                                <StackPanel>
                                    <TextBlock Text="Dashboard" Foreground="#172033" FontSize="28" FontWeight="Bold"/>
                                    <TextBlock Text="Pinned, favorit, dan shortcut terakhir yang digunakan."
                                               Foreground="#667085" Margin="0,5,0,0"/>
                                </StackPanel>
                                <Button x:Name="BtnAddDashboard" DockPanel.Dock="Right"
                                        Style="{StaticResource ActionButton}" Content="+ Tambah Shortcut"/>
                            </DockPanel>

                            <Grid Margin="0,0,0,14">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#E2E8F0"
                                        BorderThickness="1" CornerRadius="12" Margin="0,0,8,0" Padding="15">
                                    <StackPanel>
                                        <TextBlock Text="SHORTCUT" Foreground="#98A2B3" FontSize="9" FontWeight="Bold"/>
                                        <TextBlock x:Name="TxtShortcutCount" Text="0" Foreground="#172033"
                                                   FontSize="26" FontWeight="Bold" Margin="0,4,0,0"/>
                                        <TextBlock Text="tersimpan" Foreground="#667085" FontSize="11"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="1" Background="#FFFFFF" BorderBrush="#E2E8F0"
                                        BorderThickness="1" CornerRadius="12" Margin="4,0" Padding="15">
                                    <StackPanel>
                                        <TextBlock Text="KOMPUTER" Foreground="#98A2B3" FontSize="9" FontWeight="Bold"/>
                                        <TextBlock x:Name="TxtComputer" Text="-" Foreground="#172033"
                                                   FontSize="17" FontWeight="Bold" Margin="0,6,0,0"/>
                                        <TextBlock x:Name="TxtUser" Text="-" Foreground="#667085" FontSize="11"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="2" Background="#FFFFFF" BorderBrush="#E2E8F0"
                                        BorderThickness="1" CornerRadius="12" Margin="8,0,0,0" Padding="15">
                                    <StackPanel>
                                        <TextBlock Text="WAKTU" Foreground="#98A2B3" FontSize="9" FontWeight="Bold"/>
                                        <TextBlock x:Name="TxtTime" Text="--:--:--" Foreground="#172033"
                                                   FontSize="17" FontWeight="Bold" Margin="0,6,0,0"/>
                                        <TextBlock x:Name="TxtDate" Text="-" Foreground="#667085" FontSize="11"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <Border Background="#EFF6FF" BorderBrush="#DBEAFE" BorderThickness="1"
                                    CornerRadius="9" Padding="10" Margin="0,0,0,16">
                                <TextBlock Text="Tip: tarik file atau folder ke jendela ini untuk membuat shortcut otomatis. Command Palette: Ctrl+K."
                                           Foreground="#475467" FontSize="10.5"/>
                            </Border>

                            <TextBlock Text="Pinned" Foreground="#172033" FontSize="17" FontWeight="SemiBold"/>
                            <TextBlock Text="Shortcut yang sengaja dipasang di Dashboard."
                                       Foreground="#98A2B3" FontSize="10" Margin="0,2,0,6"/>
                            <WrapPanel x:Name="DashboardPinned" Margin="0,0,0,16"/>

                            <TextBlock Text="Favorit" Foreground="#172033" FontSize="17" FontWeight="SemiBold"/>
                            <TextBlock Text="Shortcut favorit untuk akses cepat."
                                       Foreground="#98A2B3" FontSize="10" Margin="0,2,0,6"/>
                            <WrapPanel x:Name="DashboardFavorites" Margin="0,0,0,16"/>

                            <TextBlock Text="Terbaru" Foreground="#172033" FontSize="17" FontWeight="SemiBold"/>
                            <TextBlock Text="Shortcut yang terakhir dibuka dari aplikasi."
                                       Foreground="#98A2B3" FontSize="10" Margin="0,2,0,6"/>
                            <WrapPanel x:Name="DashboardRecent"/>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
                <Grid x:Name="PageShortcuts" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Text="Shortcut Saya" Foreground="#172033" FontSize="26" FontWeight="Bold"/>
                            <TextBlock Text="Kelola, cari, filter, dan ubah mode tampilan shortcut."
                                       Foreground="#667085" Margin="0,4,0,0"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                            <Button x:Name="BtnExportShortcut" Style="{StaticResource SecondaryButton}" Content="Export"/>
                            <Button x:Name="BtnImportShortcut" Style="{StaticResource SecondaryButton}" Content="Import"/>
                            <Button x:Name="BtnAddShortcut" Style="{StaticResource ActionButton}" Content="+ Tambah"/>
                        </StackPanel>
                    </Grid>

                    <Border Grid.Row="1" Margin="0,16,0,14"
                            Background="#FFFFFF" BorderBrush="#E4E7EC"
                            BorderThickness="1" CornerRadius="12" Padding="8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="100"/>
                                <ColumnDefinition Width="120"/>
                                <ColumnDefinition Width="105"/>
                                <ColumnDefinition Width="95"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Height="36" Margin="0,0,8,0"
                                    Background="#F8FAFC" BorderBrush="#E4E7EC"
                                    BorderThickness="1" CornerRadius="9">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="32"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Path Grid.Column="0"
                                          Data="M 11,11 m -4.5,0 a 4.5,4.5 0 1,0 9,0 a 4.5,4.5 0 1,0 -9,0 M 14.3,14.3 L 18.5,18.5"
                                          Stroke="#98A2B3" StrokeThickness="1.25"
                                          Width="16" Height="16" Stretch="Uniform"
                                          HorizontalAlignment="Center"
                                          VerticalAlignment="Center"/>
                                    <TextBox x:Name="TxtSearch" Grid.Column="1"
                                             Style="{StaticResource ModernSearchBox}"
                                             ToolTip="Cari nama, tipe, kategori, atau target"/>
                                </Grid>
                            </Border>

                            <ComboBox x:Name="CmbFilterType" Grid.Column="1"
                                      Style="{StaticResource ModernComboBox}"
                                      Margin="0,0,8,0" SelectedIndex="0"
                                      ToolTip="Filter tipe">
                                <ComboBoxItem Content="Semua Tipe"/>
                                <ComboBoxItem Content="Folder"/>
                                <ComboBoxItem Content="File"/>
                                <ComboBoxItem Content="App"/>
                                <ComboBoxItem Content="URL"/>
                                <ComboBoxItem Content="PowerShell"/>
                            </ComboBox>

                            <ComboBox x:Name="CmbFilterCategory" Grid.Column="2"
                                      Style="{StaticResource ModernComboBox}"
                                      Margin="0,0,8,0"
                                      SelectedIndex="0" ToolTip="Filter kategori">
                                <ComboBoxItem Content="Semua Kategori"/>
                            </ComboBox>

                            <ComboBox x:Name="CmbShortcutStatus" Grid.Column="3"
                                      Style="{StaticResource ModernComboBox}"
                                      Margin="0,0,8,0"
                                      SelectedIndex="0" ToolTip="Filter status">
                                <ComboBoxItem Content="Semua"/>
                                <ComboBoxItem Content="Favorit"/>
                                <ComboBoxItem Content="Dipin"/>
                                <ComboBoxItem Content="Terbaru"/>
                                <ComboBoxItem Content="Sering Dibuka"/>
                            </ComboBox>

                            <ComboBox x:Name="CmbShortcutView" Grid.Column="4"
                                      Style="{StaticResource ModernComboBox}"
                                      SelectedIndex="0" ToolTip="Mode tampilan">
                                <ComboBoxItem Content="Grid"/>
                                <ComboBoxItem Content="List"/>
                                <ComboBoxItem Content="Compact"/>
                            </ComboBox>
                        </Grid>
                    </Border>

                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <WrapPanel x:Name="ShortcutPanel"/>
                    </ScrollViewer>
                </Grid>
                <Grid x:Name="PageTools" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0">
                        <TextBlock Text="Windows Tools &amp; Data" Foreground="#172033" FontSize="26" FontWeight="Bold"/>
                        <TextBlock Text="Cari dan filter utility Windows, terminal, network, serta maintenance data."
                                   Foreground="#667085" Margin="0,4,0,0"/>
                    </StackPanel>

                    <Border Grid.Row="1" Margin="0,16,0,14"
                            Background="#FFFFFF" BorderBrush="#E4E7EC"
                            BorderThickness="1" CornerRadius="12" Padding="8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="155"/>
                                <ColumnDefinition Width="108"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Height="36" Margin="0,0,8,0"
                                    Background="#F8FAFC" BorderBrush="#E4E7EC"
                                    BorderThickness="1" CornerRadius="9">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="32"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Path Grid.Column="0"
                                          Data="M 11,11 m -4.5,0 a 4.5,4.5 0 1,0 9,0 a 4.5,4.5 0 1,0 -9,0 M 14.3,14.3 L 18.5,18.5"
                                          Stroke="#98A2B3" StrokeThickness="1.25"
                                          Width="16" Height="16" Stretch="Uniform"
                                          HorizontalAlignment="Center"
                                          VerticalAlignment="Center"/>
                                    <TextBox x:Name="TxtToolSearch" Grid.Column="1"
                                             Style="{StaticResource ModernSearchBox}"
                                             ToolTip="Cari Windows Tools"/>
                                </Grid>
                            </Border>

                            <ComboBox x:Name="CmbToolCategory" Grid.Column="1"
                                      Style="{StaticResource ModernComboBox}"
                                      Margin="0,0,8,0"
                                      SelectedIndex="0" ToolTip="Filter kategori">
                                <ComboBoxItem Content="Semua Kategori"/>
                                <ComboBoxItem Content="File &amp; Folder"/>
                                <ComboBoxItem Content="System"/>
                                <ComboBoxItem Content="Management"/>
                                <ComboBoxItem Content="Network"/>
                                <ComboBoxItem Content="Terminal"/>
                                <ComboBoxItem Content="Data &amp; Recovery"/>
                            </ComboBox>

                            <ComboBox x:Name="CmbToolView" Grid.Column="2"
                                      Style="{StaticResource ModernComboBox}"
                                      SelectedIndex="0" ToolTip="Mode tampilan">
                                <ComboBoxItem Content="Grid"/>
                                <ComboBoxItem Content="List"/>
                                <ComboBoxItem Content="Compact"/>
                            </ComboBox>
                        </Grid>
                    </Border>

                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <WrapPanel x:Name="ToolsPanel"/>
                    </ScrollViewer>
                </Grid>
                <Grid x:Name="PageGlobalSearch" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0">
                        <TextBlock Text="Hasil Pencarian" Foreground="#172033" FontSize="26" FontWeight="Bold"/>
                        <TextBlock x:Name="TxtGlobalResultCount" Text="0 hasil"
                                   Foreground="#667085" Margin="0,4,0,0"/>
                    </StackPanel>

                    <ScrollViewer Grid.Row="1" Margin="0,16,0,0"
                                  VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Disabled">
                        <StackPanel>
                            <TextBlock Text="Shortcut" Foreground="#344054" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
                            <WrapPanel x:Name="GlobalShortcutPanel" Margin="0,0,0,18"/>

                            <TextBlock Text="Windows Tools" Foreground="#344054" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
                            <WrapPanel x:Name="GlobalToolsPanel"/>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <Grid x:Name="PageSystem" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <DockPanel Grid.Row="0">
                        <StackPanel>
                            <TextBlock Text="System Info" Foreground="#172033" FontSize="28" FontWeight="Bold"/>
                            <TextBlock Text="Ringkasan perangkat dan sistem operasi Windows."
                                       Foreground="#667085" Margin="0,5,0,0"/>
                        </StackPanel>
                        <Button x:Name="BtnRefreshSystem" DockPanel.Dock="Right"
                                Style="{StaticResource SecondaryButton}" Content="Refresh" VerticalAlignment="Top"/>
                    </DockPanel>

                    <ScrollViewer Grid.Row="1" Margin="0,18,0,0" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <Border Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="1"
                                    CornerRadius="12" Padding="16" Margin="0,0,0,12">
                                <StackPanel>
                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel>
                                            <TextBlock Text="Live Monitor" Foreground="#172033"
                                                       FontSize="17" FontWeight="SemiBold"/>
                                            <TextBlock Text="Aktif hanya saat halaman System Info dibuka."
                                                       Foreground="#98A2B3" FontSize="10"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <TextBlock x:Name="TxtLiveMonitorStatus"
                                                   Grid.Column="1"
                                                   Text="Standby"
                                                   Foreground="#667085"
                                                   FontSize="10"
                                                   VerticalAlignment="Center"/>
                                    </Grid>

                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>

                                        <Border Grid.Column="0" Background="#F8FAFC"
                                                BorderBrush="#EAECF0" BorderThickness="1"
                                                CornerRadius="10" Padding="12" Margin="0,0,6,0">
                                            <StackPanel>
                                                <TextBlock Text="CPU" Foreground="#98A2B3"
                                                           FontSize="9" FontWeight="Bold"/>
                                                <TextBlock x:Name="TxtLiveCPU" Text="-- %"
                                                           Foreground="#172033"
                                                           FontSize="20" FontWeight="Bold"
                                                           Margin="0,4,0,7"/>
                                                <ProgressBar x:Name="BarLiveCPU"
                                                             Height="5" Minimum="0" Maximum="100"
                                                             Value="0" BorderThickness="0"/>
                                            </StackPanel>
                                        </Border>

                                        <Border Grid.Column="1" Background="#F8FAFC"
                                                BorderBrush="#EAECF0" BorderThickness="1"
                                                CornerRadius="10" Padding="12" Margin="3,0">
                                            <StackPanel>
                                                <TextBlock Text="RAM" Foreground="#98A2B3"
                                                           FontSize="9" FontWeight="Bold"/>
                                                <TextBlock x:Name="TxtLiveRAM" Text="-- %"
                                                           Foreground="#172033"
                                                           FontSize="20" FontWeight="Bold"
                                                           Margin="0,4,0,7"/>
                                                <ProgressBar x:Name="BarLiveRAM"
                                                             Height="5" Minimum="0" Maximum="100"
                                                             Value="0" BorderThickness="0"/>
                                            </StackPanel>
                                        </Border>

                                        <Border Grid.Column="2" Background="#F8FAFC"
                                                BorderBrush="#EAECF0" BorderThickness="1"
                                                CornerRadius="10" Padding="12" Margin="6,0,0,0">
                                            <StackPanel>
                                                <TextBlock Text="NETWORK" Foreground="#98A2B3"
                                                           FontSize="9" FontWeight="Bold"/>
                                                <TextBlock x:Name="TxtLiveNetwork"
                                                           Text="↓ --  ↑ --"
                                                           Foreground="#172033"
                                                           FontSize="11"
                                                           FontWeight="SemiBold"
                                                           Margin="0,8,0,0"
                                                           TextTrimming="CharacterEllipsis"/>
                                            </StackPanel>
                                        </Border>
                                    </Grid>
                                </StackPanel>
                            </Border>

                            <Border Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="1"
                                    CornerRadius="12" Padding="20" Margin="0,0,0,12">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="165"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>

                                    <TextBlock Grid.Row="0" Text="Computer" Foreground="#667085" Margin="0,6"/>
                                    <TextBlock Grid.Row="0" Grid.Column="1" x:Name="SysComputer" Foreground="#172033" FontWeight="SemiBold" Margin="0,6"/>
                                    <TextBlock Grid.Row="1" Text="User" Foreground="#667085" Margin="0,6"/>
                                    <TextBlock Grid.Row="1" Grid.Column="1" x:Name="SysUser" Foreground="#172033" Margin="0,6"/>
                                    <TextBlock Grid.Row="2" Text="Windows" Foreground="#667085" Margin="0,6"/>
                                    <TextBlock Grid.Row="2" Grid.Column="1" x:Name="SysWindows" Foreground="#172033" TextWrapping="Wrap" Margin="0,6"/>
                                    <TextBlock Grid.Row="3" Text="Version" Foreground="#667085" Margin="0,6"/>
                                    <TextBlock Grid.Row="3" Grid.Column="1" x:Name="SysVersion" Foreground="#172033" Margin="0,6"/>
                                    <TextBlock Grid.Row="4" Text="CPU" Foreground="#667085" Margin="0,6"/>
                                    <TextBlock Grid.Row="4" Grid.Column="1" x:Name="SysCPU" Foreground="#172033" TextWrapping="Wrap" Margin="0,6"/>
                                    <TextBlock Grid.Row="5" Text="RAM" Foreground="#667085" Margin="0,6"/>
                                    <TextBlock Grid.Row="5" Grid.Column="1" x:Name="SysRAM" Foreground="#172033" Margin="0,6"/>
                                    <TextBlock Grid.Row="6" Text="Uptime" Foreground="#667085" Margin="0,6"/>
                                    <TextBlock Grid.Row="6" Grid.Column="1" x:Name="SysUptime" Foreground="#172033" Margin="0,6"/>
                                </Grid>
                            </Border>

                            <Border Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="1"
                                    CornerRadius="12" Padding="20">
                                <StackPanel>
                                    <TextBlock Text="Disk" Foreground="#172033" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,10"/>
                                    <ItemsControl x:Name="SysDisks" Foreground="#344054"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                    <Border x:Name="SystemLoadingPanel"
                            Grid.RowSpan="2"
                            Background="#F8FFFFFF"
                            Visibility="Collapsed"
                            Panel.ZIndex="20">
                        <Grid>
                            <Border Width="310" Padding="22,18"
                                    Background="#FFFFFF"
                                    BorderBrush="#E4E7EC"
                                    BorderThickness="1"
                                    CornerRadius="12"
                                    HorizontalAlignment="Center"
                                    VerticalAlignment="Center">
                                <StackPanel>
                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="Auto"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Border Width="34" Height="34"
                                                Background="#EFF6FF"
                                                CornerRadius="9"
                                                VerticalAlignment="Center">
                                            <Path Data="M 8,2 A 6,6 0 1,1 3.75,3.75"
                                                  Stroke="#2563EB"
                                                  StrokeThickness="1.8"
                                                  StrokeStartLineCap="Round"
                                                  Width="18" Height="18"
                                                  Stretch="Uniform"
                                                  HorizontalAlignment="Center"
                                                  VerticalAlignment="Center"/>
                                        </Border>
                                        <StackPanel Grid.Column="1" Margin="11,0,0,0" VerticalAlignment="Center">
                                            <TextBlock Text="Memuat System Info"
                                                       Foreground="#172033"
                                                       FontSize="13"
                                                       FontWeight="SemiBold"/>
                                            <TextBlock Text="Membaca CPU, RAM, uptime, dan disk..."
                                                       Foreground="#667085"
                                                       FontSize="10"
                                                       Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Grid>

                                    <ProgressBar Height="4"
                                                 IsIndeterminate="True"
                                                 Foreground="#2563EB"
                                                 Background="#EFF6FF"
                                                 BorderThickness="0"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </Border>
                </Grid>

                <Grid x:Name="PageSettings" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0">
                        <TextBlock Text="Settings" Foreground="#172033" FontSize="26" FontWeight="Bold"/>
                        <TextBlock Text="Atur startup Windows, System Tray, perilaku tombol Close, dan global hotkey."
                                   Foreground="#667085" Margin="0,4,0,0"/>
                    </StackPanel>

                    <ScrollViewer Grid.Row="1" Margin="0,16,0,0" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <Border Background="#FFFFFF" BorderBrush="#E4E7EC" BorderThickness="1"
                                    CornerRadius="12" Padding="18" Margin="0,0,0,12">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Bahasa Aplikasi"
                                                   Foreground="#172033" FontSize="16" FontWeight="SemiBold"/>
                                        <TextBlock Text="Pilih bahasa untuk seluruh menu, tombol, keterangan, dialog, dan panduan."
                                                   Foreground="#98A2B3" FontSize="10" Margin="0,3,0,0"
                                                   TextWrapping="Wrap"/>
                                    </StackPanel>
                                    <ComboBox x:Name="CmbLanguage"
                                              Grid.Column="1"
                                              Style="{StaticResource ModernComboBox}"
                                              Width="180"
                                              Margin="16,0,0,0"
                                              VerticalAlignment="Center"
                                              SelectedIndex="0">
                                        <ComboBoxItem Content="Bahasa Indonesia" Tag="id"/>
                                        <ComboBoxItem Content="English" Tag="en"/>
                                    </ComboBox>
                                </Grid>
                            </Border>

                            <Border Background="#FFFFFF" BorderBrush="#E4E7EC" BorderThickness="1"
                                    CornerRadius="12" Padding="18" Margin="0,0,0,12">
                                <StackPanel>
                                    <TextBlock Text="Startup &amp; Window"
                                               Foreground="#172033" FontSize="16" FontWeight="SemiBold"/>
                                    <TextBlock Text="Atur bagaimana aplikasi berjalan saat masuk Windows dan ketika jendela ditutup."
                                               Foreground="#98A2B3" FontSize="10" Margin="0,3,0,14"/>

                                    <CheckBox x:Name="ChkRunAtStartup"
                                              Content="Jalankan otomatis saat login Windows"
                                              Foreground="#344054" Margin="0,4,0,8"/>

                                    <CheckBox x:Name="ChkStartInTray"
                                              Content="Mulai langsung di System Tray"
                                              Foreground="#344054" Margin="0,4,0,12"/>

                                    <TextBlock Text="Saat tombol Close ditekan"
                                               Foreground="#344054" FontSize="11"
                                               FontWeight="SemiBold" Margin="0,0,0,6"/>

                                    <ComboBox x:Name="CmbCloseBehavior"
                                              Style="{StaticResource ModernComboBox}"
                                              Width="210"
                                              HorizontalAlignment="Left"
                                              SelectedIndex="0">
                                        <ComboBoxItem Content="Keluar dari aplikasi" Tag="Exit"/>
                                        <ComboBoxItem Content="Minimize ke System Tray" Tag="Tray"/>
                                    </ComboBox>
                                </StackPanel>
                            </Border>

                            <Border Background="#FFFFFF" BorderBrush="#E4E7EC" BorderThickness="1"
                                    CornerRadius="12" Padding="18" Margin="0,0,0,12">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>

                                    <StackPanel>
                                        <TextBlock Text="Global Hotkey"
                                                   Foreground="#172033" FontSize="16" FontWeight="SemiBold"/>
                                        <TextBlock Text="Buka Windows Shortcut Control dari aplikasi mana pun."
                                                   Foreground="#98A2B3" FontSize="10" Margin="0,3,0,12"/>

                                        <CheckBox x:Name="ChkGlobalHotkey"
                                                  Content="Aktifkan Ctrl + Alt + Space"
                                                  Foreground="#344054" Margin="0,0,0,8"/>

                                        <TextBlock x:Name="TxtHotkeyStatus"
                                                   Text="Status: belum diterapkan"
                                                   Foreground="#667085" FontSize="10"/>
                                    </StackPanel>

                                    <Border Grid.Column="1"
                                            Background="#F8FAFC"
                                            BorderBrush="#EAECF0"
                                            BorderThickness="1"
                                            CornerRadius="9"
                                            Padding="12,8"
                                            VerticalAlignment="Center">
                                        <TextBlock Text="Ctrl + Alt + Space"
                                                   Foreground="#344054"
                                                   FontSize="11"
                                                   FontWeight="SemiBold"/>
                                    </Border>
                                </Grid>
                            </Border>

                            <Border Background="#FFFFFF" BorderBrush="#E4E7EC"
                                    BorderThickness="1" CornerRadius="12"
                                    Padding="18" Margin="0,0,0,12">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>

                                    <StackPanel>
                                        <TextBlock Text="Bantuan &amp; Panduan"
                                                   Foreground="#172033"
                                                   FontSize="16"
                                                   FontWeight="SemiBold"/>
                                        <TextBlock Text="Buka kembali panduan kapan saja untuk mempelajari menu utama dan cara penggunaan aplikasi."
                                                   Foreground="#98A2B3"
                                                   FontSize="10"
                                                   Margin="0,3,0,0"
                                                   TextWrapping="Wrap"/>
                                    </StackPanel>

                                    <Button x:Name="BtnOpenGettingStarted"
                                            Grid.Column="1"
                                            Style="{StaticResource SecondaryButton}"
                                            Content="Panduan Penggunaan"
                                            VerticalAlignment="Center"
                                            Margin="12,0,0,0"/>
                                </Grid>
                            </Border>

                            <Border Background="#FFFFFF" BorderBrush="#E4E7EC"
                                    BorderThickness="1" CornerRadius="12"
                                    Padding="18" Margin="0,0,0,12">
                                <StackPanel>
                                    <TextBlock Text="Backup &amp; Diagnostics"
                                               Foreground="#172033"
                                               FontSize="16"
                                               FontWeight="SemiBold"/>
                                    <TextBlock Text="Backup semua shortcut + settings, restore, atau periksa kesehatan aplikasi."
                                               Foreground="#98A2B3"
                                               FontSize="10"
                                               Margin="0,3,0,12"/>

                                    <WrapPanel>
                                        <Button x:Name="BtnExportFullConfig"
                                                Style="{StaticResource SecondaryButton}"
                                                Content="Backup Config"/>
                                        <Button x:Name="BtnImportFullConfig"
                                                Style="{StaticResource SecondaryButton}"
                                                Content="Restore Config"/>
                                        <Button x:Name="BtnRunDiagnostics"
                                                Style="{StaticResource SecondaryButton}"
                                                Content="Self Diagnostics"/>
                                    </WrapPanel>

                                    <TextBlock x:Name="TxtDiagnosticsSummary"
                                               Text="Diagnostics belum dijalankan."
                                               Foreground="#667085"
                                               FontSize="10"
                                               Margin="4,8,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Background="#EFF6FF" BorderBrush="#DBEAFE" BorderThickness="1"
                                    CornerRadius="10" Padding="12" Margin="0,0,0,14">
                                <TextBlock Foreground="#475467" FontSize="10.5" TextWrapping="Wrap"
                                           Text="System Tray tetap menjaga aplikasi aktif tanpa memenuhi taskbar. Global hotkey akan membuka aplikasi sekaligus Command Palette."/>
                            </Border>

                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                <Button x:Name="BtnMinimizeToTray"
                                        Style="{StaticResource SecondaryButton}"
                                        Content="Test System Tray"/>
                                <Button x:Name="BtnSaveSettings"
                                        Style="{StaticResource ActionButton}"
                                        Content="Simpan Settings"/>
                            </StackPanel>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

            </Grid>
        </Grid>

        <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0">
            <Grid Margin="14,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="TxtStatus" Text="Siap" Foreground="#667085" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtStatusRight" Grid.Column="1" Text="" Foreground="#98A2B3" FontSize="11" VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Resolve named elements
$names = @(
    'TopBar','BtnMinimize','BtnMaximize','BtnClose',
    'TxtGlobalSearch','TxtGlobalSearchHint','BtnClearGlobalSearch',
    'NavDashboard','NavShortcuts','NavTools','NavSystem','NavSettings',
    'BtnOpenScriptFolder','BtnAbout',
    'PageDashboard','PageShortcuts','PageTools','PageGlobalSearch','PageSystem','PageSettings',
    'TxtGlobalResultCount','GlobalShortcutPanel','GlobalToolsPanel',
    'TxtShortcutCount','TxtComputer','TxtUser','TxtTime','TxtDate',
    'BtnAddDashboard','DashboardPinned','DashboardFavorites','DashboardRecent',
    'BtnAddShortcut','BtnExportShortcut','BtnImportShortcut',
    'TxtSearch','CmbFilterType','CmbFilterCategory','CmbShortcutStatus','CmbShortcutView','ShortcutPanel',
    'TxtToolSearch','CmbToolCategory','CmbToolView','ToolsPanel',
    'BtnRefreshSystem','SystemLoadingPanel',
    'SysComputer','SysUser','SysWindows','SysVersion','SysCPU','SysRAM','SysUptime','SysDisks',
    'TxtLiveCPU','BarLiveCPU','TxtLiveRAM','BarLiveRAM','TxtLiveNetwork','TxtLiveMonitorStatus',
    'CmbLanguage',
    'ChkRunAtStartup','ChkStartInTray','CmbCloseBehavior','ChkGlobalHotkey','TxtHotkeyStatus',
    'BtnMinimizeToTray','BtnSaveSettings',
    'BtnExportFullConfig','BtnImportFullConfig','BtnRunDiagnostics','TxtDiagnosticsSummary',
    'BtnOpenGettingStarted',
    'TxtStatus','TxtStatusRight'
)

foreach ($n in $names) {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

function Set-Status([string]$Text) {
    $script:TxtStatus.Text = Convert-UiText $Text
}

function Get-ComboContent([object]$Combo, [string]$Default='') {
    try {
        if ($null -eq $Combo -or $null -eq $Combo.SelectedItem) { return $Default }
        $item = $Combo.SelectedItem
        if ($item -is [System.Windows.Controls.ComboBoxItem]) {
            return (Get-CanonicalUiValue ([string]$item.Content))
        }
        return (Get-CanonicalUiValue ([string]$item))
    } catch {
        return $Default
    }
}

function Show-Page([string]$Name) {
    if ($Name -ne 'System') { Stop-SystemMonitor }
    $script:PageDashboard.Visibility = 'Collapsed'
    $script:PageShortcuts.Visibility = 'Collapsed'
    $script:PageTools.Visibility = 'Collapsed'
    $script:PageGlobalSearch.Visibility = 'Collapsed'
    $script:PageSystem.Visibility = 'Collapsed'
    $script:PageSettings.Visibility = 'Collapsed'

    switch ($Name) {
        'Dashboard' { $script:PageDashboard.Visibility = 'Visible'; Refresh-DashboardViews }
        'Shortcuts' { $script:PageShortcuts.Visibility = 'Visible'; Refresh-ShortcutViews }
        'Tools'     { $script:PageTools.Visibility = 'Visible'; Refresh-ToolViews }
        'Search'    { $script:PageGlobalSearch.Visibility = 'Visible' }
        'System'    { $script:PageSystem.Visibility = 'Visible'; Show-SystemInfoPage }
        'Settings'  { $script:PageSettings.Visibility = 'Visible'; Apply-SettingsToUI }
    }

    if ($Name -ne 'Search') {
        $script:LastPage = $Name
        $script:LastNonSearchPage = $Name
    }
    Set-Status $Name
}


function Get-ShortcutById([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }

    foreach ($item in @($script:ShortcutStore)) {
        if ($null -ne $item -and [string]$item.Id -eq [string]$Id) {
            return $item
        }
    }

    return $null
}

function Invoke-ShortcutMenuAction([string]$ActionAndId) {
    try {
        if ([string]::IsNullOrWhiteSpace($ActionAndId)) {
            throw 'Data menu shortcut kosong.'
        }

        $sep = $ActionAndId.IndexOf('|')
        if ($sep -lt 1) {
            throw "Format aksi shortcut tidak valid: $ActionAndId"
        }

        $action = $ActionAndId.Substring(0, $sep)
        $id = $ActionAndId.Substring($sep + 1)
        $item = Get-ShortcutById $id

        if (-not $item) {
            throw 'Shortcut tidak ditemukan. Coba tutup lalu buka kembali aplikasi.'
        }

        switch ($action) {
            'Open' {
                Open-Target $item
            }
            'Parent' {
                Open-ParentFolder $item
            }
            'Copy' {
                Set-ClipboardText ([string]$item.Target)
                Set-Status "Target '$($item.Name)' disalin ke Clipboard."
            }
            'Favorite' { Toggle-ShortcutFlag ([string]$item.Id) 'Favorite' }
            'Pin' { Toggle-ShortcutFlag ([string]$item.Id) 'Pinned' }
            'Edit' { Edit-ShortcutDialog ([string]$item.Id) }
            'Duplicate' { Duplicate-Shortcut $item }
            'Terminal' { Open-TerminalForShortcut $item }
            'Admin' { Run-ShortcutAsAdmin $item }
            'Up' { Move-Shortcut ([string]$item.Id) -1 }
            'Down' { Move-Shortcut ([string]$item.Id) 1 }
            'Delete' { Remove-Shortcut ([string]$item.Id) }
            default {
                throw "Aksi tidak dikenal: $action"
            }
        }
    } catch {
        Show-Error $_.Exception.Message 'Shortcut'
        Set-Status 'Aksi shortcut gagal.'
    }
}

function New-ShortcutCard([pscustomobject]$Item, [switch]$Compact) {
    if ($null -eq $Item) { return $null }

    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $window.Resources['ShortcutButton']

    if ($Compact) {
        $btn.Width = 178
        $btn.Height = 98
    }

    $isHealthy = $false
    try { $isHealthy = [bool](Test-ShortcutTarget $Item) } catch { $isHealthy = $false }

    $visualText = 'ITM'
    $visualBg = '#F2F4F7'
    $visualFg = '#475467'

    switch ([string]$Item.Type) {
        'Folder' {
            $visualText = 'DIR'
            $visualBg = '#FFF7ED'
            $visualFg = '#C2410C'
        }
        'File' {
            $visualText = 'FILE'
            try {
                $extension = [IO.Path]::GetExtension([string]$Item.Target)
                if (-not [string]::IsNullOrWhiteSpace($extension)) {
                    $candidate = $extension.TrimStart('.').ToUpperInvariant()
                    if ($candidate.Length -le 5) { $visualText = $candidate }
                }
            } catch {}
            $visualBg = '#F0FDF4'
            $visualFg = '#15803D'
        }
        'App' {
            $visualText = 'APP'
            $visualBg = '#EFF6FF'
            $visualFg = '#1D4ED8'
        }
        'URL' {
            $visualText = 'WEB'
            $visualBg = '#F5F3FF'
            $visualFg = '#7C3AED'
        }
        'PowerShell' {
            $visualText = 'PS'
            $visualBg = '#F0F9FF'
            $visualFg = '#0369A1'
        }
    }

    $grid = New-Object System.Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height='*'}))

    # Header: realistic file/app tile + title + health indicator.
    $header = New-Object System.Windows.Controls.Grid
    $header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='Auto'}))
    $header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='*'}))
    $header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='Auto'}))

    $iconTile = New-Object System.Windows.Controls.Border
    $iconTile.Width = 38
    $iconTile.Height = 38
    $iconTile.CornerRadius = '9'
    $iconTile.Background = $visualBg
    $iconTile.VerticalAlignment = 'Center'
    $iconTile.Margin = '0,0,10,0'

    $iconText = New-Object System.Windows.Controls.TextBlock
    $iconText.Text = $visualText
    $iconText.Foreground = $visualFg
    $iconText.FontSize = if ($visualText.Length -gt 3) { 8 } else { 10 }
    $iconText.FontWeight = 'Bold'
    $iconText.HorizontalAlignment = 'Center'
    $iconText.VerticalAlignment = 'Center'
    $iconTile.Child = $iconText

    [System.Windows.Controls.Grid]::SetColumn($iconTile,0)
    [void]$header.Children.Add($iconTile)

    $titleStack = New-Object System.Windows.Controls.StackPanel
    $titleStack.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($titleStack,1)

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = [string]$Item.Name
    $name.Foreground = '#172033'
    $name.FontSize = 13
    $name.FontWeight = 'SemiBold'
    $name.TextTrimming = 'CharacterEllipsis'
    $name.MaxWidth = if ($Compact) { 92 } else { 105 }

    $type = New-Object System.Windows.Controls.TextBlock
    $type.Text = ([string]$Item.Type).ToUpperInvariant()
    $type.Foreground = '#98A2B3'
    $type.FontSize = 9
    $type.FontWeight = 'SemiBold'
    $type.Margin = '0,2,0,0'

    [void]$titleStack.Children.Add($name)
    [void]$titleStack.Children.Add($type)
    [void]$header.Children.Add($titleStack)

    $health = New-Object System.Windows.Shapes.Ellipse
    $health.Width = 7
    $health.Height = 7
    $health.Margin = '5,3,1,0'
    $health.VerticalAlignment = 'Top'
    $health.Fill = if ($isHealthy) { '#22C55E' } else { '#EF4444' }
    $health.ToolTip = if ($isHealthy) { L 'Target tersedia' 'Target available' } else { L 'Target tidak ditemukan / belum valid' 'Target not found / not valid' }
    [System.Windows.Controls.Grid]::SetColumn($health,2)
    [void]$header.Children.Add($health)

    [System.Windows.Controls.Grid]::SetRow($header,0)
    [void]$grid.Children.Add($header)

    # Category chip.
    $chip = New-Object System.Windows.Controls.Border
    $chip.Background = '#F8FAFC'
    $chip.BorderBrush = '#EAECF0'
    $chip.BorderThickness = '1'
    $chip.CornerRadius = '5'
    $chip.Padding = '6,2'
    $chip.Margin = '0,8,0,0'
    $chip.HorizontalAlignment = 'Left'

    $chipText = New-Object System.Windows.Controls.TextBlock
    $metaParts = New-Object System.Collections.Generic.List[string]
    $categoryLabel = if ([string]::IsNullOrWhiteSpace([string]$Item.Category)) {
        'Custom'
    } else {
        [string]$Item.Category
    }
    [void]$metaParts.Add($categoryLabel)
    if ([bool]$Item.Pinned) { [void]$metaParts.Add('PIN') }
    elseif ([bool]$Item.Favorite) { [void]$metaParts.Add('FAV') }
    if ([int]$Item.OpenCount -gt 0) { [void]$metaParts.Add(("$($Item.OpenCount)x")) }
    $chipText.Text = [string]::Join('  ·  ', $metaParts.ToArray())
    $chipText.Foreground = '#667085'
    $chipText.FontSize = 9
    $chipText.MaxWidth = if ($Compact) { 130 } else { 142 }
    $chipText.TextTrimming = 'CharacterEllipsis'
    $chip.Child = $chipText

    [System.Windows.Controls.Grid]::SetRow($chip,1)
    [void]$grid.Children.Add($chip)

    # Target/path line.
    $target = New-Object System.Windows.Controls.TextBlock
    $target.Text = [string]$Item.Target
    $target.Foreground = '#98A2B3'
    $target.FontSize = 9
    $target.TextWrapping = 'NoWrap'
    $target.TextTrimming = 'CharacterEllipsis'
    $target.VerticalAlignment = 'Bottom'
    $target.Margin = '0,7,0,0'
    [System.Windows.Controls.Grid]::SetRow($target,2)
    [void]$grid.Children.Add($target)

    $btn.Content = $grid

    if (-not $isHealthy) {
        $btn.BorderBrush = '#FECACA'
        $btn.ToolTip = "$($Item.Name)`n$($Item.Type)`n$($Item.Target)`n`nTarget kosong, tidak ditemukan, atau tidak valid. Klik kanan > Edit Shortcut untuk memperbaiki."
    } else {
        $btn.ToolTip = "$($Item.Name)`n$($Item.Type)`n$($Item.Target)"
    }

    $btn.Tag = "Open|$($Item.Id)"
    $btn.Add_Click({
        param($sender,$e)
        Invoke-ShortcutMenuAction ([string]$sender.Tag)
    })

    $menu = New-Object System.Windows.Controls.ContextMenu
    $menu.Background = '#FFFFFF'
    $menu.Foreground = '#172033'
    $menu.BorderBrush = '#D0D5DD'
    $menu.BorderThickness = '1'
    $menu.Padding = '3'

    $miOpen = New-Object System.Windows.Controls.MenuItem
    $miOpen.Header = (L 'Buka' 'Open')
    $miOpen.Tag = "Open|$($Item.Id)"
    $miOpen.Add_Click({
        param($sender,$e)
        Invoke-ShortcutMenuAction ([string]$sender.Tag)
    })
    [void]$menu.Items.Add($miOpen)

    $miParent = New-Object System.Windows.Controls.MenuItem
    $miParent.Header = (L 'Buka Lokasi / Parent Folder' 'Open Location / Parent Folder')
    $miParent.Tag = "Parent|$($Item.Id)"
    $miParent.Add_Click({
        param($sender,$e)
        Invoke-ShortcutMenuAction ([string]$sender.Tag)
    })
    [void]$menu.Items.Add($miParent)

    $miCopy = New-Object System.Windows.Controls.MenuItem
    $miCopy.Header = (L 'Salin Target' 'Copy Target')
    $miCopy.Tag = "Copy|$($Item.Id)"
    $miCopy.Add_Click({
        param($sender,$e)
        Invoke-ShortcutMenuAction ([string]$sender.Tag)
    })
    [void]$menu.Items.Add($miCopy)

    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $miPin = New-Object System.Windows.Controls.MenuItem
    $miPin.Header = if ([bool]$Item.Pinned) { L 'Lepas dari Dashboard' 'Unpin from Dashboard' } else { L 'Pin ke Dashboard' 'Pin to Dashboard' }
    $miPin.Tag = "Pin|$($Item.Id)"
    $miPin.Add_Click({ param($sender,$e) Invoke-ShortcutMenuAction ([string]$sender.Tag) })
    [void]$menu.Items.Add($miPin)

    $miFavorite = New-Object System.Windows.Controls.MenuItem
    $miFavorite.Header = if ([bool]$Item.Favorite) { L 'Hapus dari Favorit' 'Remove from Favorites' } else { L 'Tambah ke Favorit' 'Add to Favorites' }
    $miFavorite.Tag = "Favorite|$($Item.Id)"
    $miFavorite.Add_Click({ param($sender,$e) Invoke-ShortcutMenuAction ([string]$sender.Tag) })
    [void]$menu.Items.Add($miFavorite)

    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $miTerminal = New-Object System.Windows.Controls.MenuItem
    $miTerminal.Header = (L 'Buka Terminal di Lokasi' 'Open Terminal Here')
    $miTerminal.Tag = "Terminal|$($Item.Id)"
    $miTerminal.Add_Click({ param($sender,$e) Invoke-ShortcutMenuAction ([string]$sender.Tag) })
    $miTerminal.IsEnabled = ([string]$Item.Type -in @('Folder','File'))
    [void]$menu.Items.Add($miTerminal)

    $miAdmin = New-Object System.Windows.Controls.MenuItem
    $miAdmin.Header = (L 'Jalankan sebagai Administrator' 'Run as Administrator')
    $miAdmin.Tag = "Admin|$($Item.Id)"
    $miAdmin.Add_Click({ param($sender,$e) Invoke-ShortcutMenuAction ([string]$sender.Tag) })
    $miAdmin.IsEnabled = ([string]$Item.Type -in @('App','File','PowerShell'))
    [void]$menu.Items.Add($miAdmin)

    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $miDuplicate = New-Object System.Windows.Controls.MenuItem
    $miDuplicate.Header = (L 'Duplikat Shortcut' 'Duplicate Shortcut')
    $miDuplicate.Tag = "Duplicate|$($Item.Id)"
    $miDuplicate.Add_Click({ param($sender,$e) Invoke-ShortcutMenuAction ([string]$sender.Tag) })
    [void]$menu.Items.Add($miDuplicate)

    $miUp = New-Object System.Windows.Controls.MenuItem
    $miUp.Header = (L 'Pindah ke Atas' 'Move Up')
    $miUp.Tag = "Up|$($Item.Id)"
    $miUp.Add_Click({ param($sender,$e) Invoke-ShortcutMenuAction ([string]$sender.Tag) })
    [void]$menu.Items.Add($miUp)

    $miDown = New-Object System.Windows.Controls.MenuItem
    $miDown.Header = (L 'Pindah ke Bawah' 'Move Down')
    $miDown.Tag = "Down|$($Item.Id)"
    $miDown.Add_Click({ param($sender,$e) Invoke-ShortcutMenuAction ([string]$sender.Tag) })
    [void]$menu.Items.Add($miDown)

    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

    $miEdit = New-Object System.Windows.Controls.MenuItem
    $miEdit.Header = (L 'Edit Shortcut' 'Edit Shortcut')
    $miEdit.Tag = "Edit|$($Item.Id)"
    $miEdit.Add_Click({
        param($sender,$e)
        Invoke-ShortcutMenuAction ([string]$sender.Tag)
    })
    [void]$menu.Items.Add($miEdit)

    $miDelete = New-Object System.Windows.Controls.MenuItem
    $miDelete.Header = (L 'Hapus Shortcut' 'Delete Shortcut')
    $miDelete.Tag = "Delete|$($Item.Id)"
    $miDelete.Add_Click({
        param($sender,$e)
        Invoke-ShortcutMenuAction ([string]$sender.Tag)
    })
    [void]$menu.Items.Add($miDelete)

    $btn.ContextMenu = $menu
    return $btn
}

function Refresh-ShortcutCategoryChoices {
    if ($script:UpdatingShortcutCategory) { return }
    if ($null -eq $script:CmbFilterCategory) { return }

    try {
        $script:UpdatingShortcutCategory = $true
        $current = Get-ComboContent $script:CmbFilterCategory 'Semua Kategori'

        $categories = @(
            $script:ShortcutStore |
            ForEach-Object { [string]$_.Category } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
        )

        $script:CmbFilterCategory.Items.Clear()
        [void]$script:CmbFilterCategory.Items.Add((L 'Semua Kategori' 'All Categories'))
        foreach ($category in $categories) {
            [void]$script:CmbFilterCategory.Items.Add($category)
        }

        $index = 0
        for ($i=0; $i -lt $script:CmbFilterCategory.Items.Count; $i++) {
            if ([string]$script:CmbFilterCategory.Items[$i] -eq $current) {
                $index = $i
                break
            }
        }
        $script:CmbFilterCategory.SelectedIndex = $index
    } finally {
        $script:UpdatingShortcutCategory = $false
    }
}

function Apply-ShortcutViewMode([object]$Card, [string]$ViewMode) {
    if ($null -eq $Card) { return }

    switch ($ViewMode) {
        'List' {
            $available = 650
            try {
                if ($window.ActualWidth -gt 0) {
                    $available = [math]::Max(430, [math]::Min(760, $window.ActualWidth - 275))
                }
            } catch {}
            $Card.Width = $available
            $Card.Height = 92
            $Card.Margin = '4,4,4,5'
        }
        'Compact' {
            $Card.Width = 158
            $Card.Height = 92
            $Card.Margin = '5'
        }
        default {
            $Card.Width = 190
            $Card.Height = 108
            $Card.Margin = '6'
        }
    }
}

function Add-DashboardPlaceholder([object]$Panel, [string]$Text) {
    if ($null -eq $Panel) { return }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = '#98A2B3'
    $tb.FontSize = 11
    $tb.Margin = '6,6,0,6'
    [void]$Panel.Children.Add($tb)
}

function Refresh-DashboardViews {
    if ($null -eq $script:ShortcutStore) { return }

    $all = @($script:ShortcutStore)
    if ($null -ne $script:TxtShortcutCount) {
        $script:TxtShortcutCount.Text = [string]$all.Count
    }

    if ($null -ne $script:DashboardPinned) {
        $script:DashboardPinned.Children.Clear()
        $pinned = @($all | Where-Object { [bool]$_.Pinned } | Select-Object -First 8)
        foreach ($item in $pinned) {
            $card = New-ShortcutCard $item -Compact
            if ($null -ne $card) { [void]$script:DashboardPinned.Children.Add($card) }
        }
        if ($pinned.Count -eq 0) {
            Add-DashboardPlaceholder $script:DashboardPinned (L 'Belum ada shortcut yang dipin. Klik kanan shortcut > Pin ke Dashboard.' 'No pinned shortcuts yet. Right-click a shortcut > Pin to Dashboard.')
        }
    }

    if ($null -ne $script:DashboardFavorites) {
        $script:DashboardFavorites.Children.Clear()
        $favorites = @(
            $all |
            Where-Object { [bool]$_.Favorite } |
            Sort-Object -Property OpenCount -Descending |
            Select-Object -First 8
        )
        foreach ($item in $favorites) {
            $card = New-ShortcutCard $item -Compact
            if ($null -ne $card) { [void]$script:DashboardFavorites.Children.Add($card) }
        }
        if ($favorites.Count -eq 0) {
            Add-DashboardPlaceholder $script:DashboardFavorites (L 'Belum ada favorit. Klik kanan shortcut > Tambah ke Favorit.' 'No favorites yet. Right-click a shortcut > Add to Favorites.')
        }
    }

    if ($null -ne $script:DashboardRecent) {
        $script:DashboardRecent.Children.Clear()
        $recent = @(
            $all |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.LastOpened) } |
            Sort-Object -Property @{
                Expression = {
                    try { [datetime]$_.LastOpened }
                    catch { [datetime]::MinValue }
                }
                Descending = $true
            } |
            Select-Object -First 8
        )
        foreach ($item in $recent) {
            $card = New-ShortcutCard $item -Compact
            if ($null -ne $card) { [void]$script:DashboardRecent.Children.Add($card) }
        }
        if ($recent.Count -eq 0) {
            Add-DashboardPlaceholder $script:DashboardRecent (L 'Belum ada riwayat. Shortcut yang dibuka akan muncul di sini.' 'No history yet. Opened shortcuts will appear here.')
        }
    }
}

function Refresh-ShortcutViews {
    $all = @($script:ShortcutStore)
    Refresh-DashboardViews
    Refresh-ShortcutCategoryChoices

    $search = ''
    if ($script:TxtSearch) {
        $search = ([string]$script:TxtSearch.Text).Trim().ToLowerInvariant()
    }

    $typeFilter = Get-ComboContent $script:CmbFilterType 'Semua Tipe'
    $categoryFilter = Get-ComboContent $script:CmbFilterCategory 'Semua Kategori'
    $statusFilter = Get-ComboContent $script:CmbShortcutStatus 'Semua'
    $viewMode = Get-ComboContent $script:CmbShortcutView 'Grid'

    $filtered = @(
        $all | Where-Object {
            if ($null -eq $_) { return $false }

            $okType = ($typeFilter -eq 'Semua Tipe' -or [string]$_.Type -eq $typeFilter)
            $okCategory = ($categoryFilter -eq 'Semua Kategori' -or [string]$_.Category -eq $categoryFilter)

            $okStatus = $true
            switch ($statusFilter) {
                'Favorit'       { $okStatus = [bool]$_.Favorite }
                'Dipin'         { $okStatus = [bool]$_.Pinned }
                'Terbaru'       { $okStatus = -not [string]::IsNullOrWhiteSpace([string]$_.LastOpened) }
                'Sering Dibuka' { $okStatus = ([int]$_.OpenCount -gt 0) }
            }

            $hay = ("{0} {1} {2} {3}" -f $_.Name,$_.Type,$_.Category,$_.Target).ToLowerInvariant()
            $okSearch = ([string]::IsNullOrWhiteSpace($search) -or $hay.Contains($search))

            $okType -and $okCategory -and $okStatus -and $okSearch
        }
    )

    if ($statusFilter -eq 'Sering Dibuka') {
        $filtered = @($filtered | Sort-Object -Property OpenCount -Descending)
    }
    elseif ($statusFilter -eq 'Terbaru') {
        $filtered = @(
            $filtered | Sort-Object -Property @{
                Expression = {
                    try { [datetime]$_.LastOpened }
                    catch { [datetime]::MinValue }
                }
                Descending = $true
            }
        )
    }

    $script:ShortcutPanel.Children.Clear()
    foreach ($item in $filtered) {
        $card = New-ShortcutCard $item
        if ($null -ne $card) {
            Apply-ShortcutViewMode $card $viewMode
            [void]$script:ShortcutPanel.Children.Add($card)
        }
    }

    if ($filtered.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = (L 'Tidak ada shortcut yang cocok dengan filter.' 'No shortcuts match the current filter.')
        $empty.Foreground = '#667085'
        $empty.FontSize = 13
        $empty.Margin = '8,16'
        [void]$script:ShortcutPanel.Children.Add($empty)
    }

    Set-Status ("Shortcut: {0} dari {1}" -f $filtered.Count, $all.Count)
}

function Remove-Shortcut([string]$Id) {
    try {
        $item = Get-ShortcutById $Id
        if ($null -eq $item) {
            Show-Error 'Shortcut tidak ditemukan pada sesi aplikasi saat ini.' 'Hapus Shortcut'
            return
        }

        if (-not (Ask-Confirm "Hapus shortcut '$($item.Name)'?")) {
            return
        }

        $newStore = @()
        foreach ($entry in @($script:ShortcutStore)) {
            if ($null -eq $entry) { continue }
            if ([string]$entry.Id -ne [string]$Id) {
                $newStore += $entry
            }
        }

        $script:ShortcutStore = @($newStore)
        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status "Shortcut '$($item.Name)' dihapus."
    } catch {
        Show-Error $_.Exception.Message 'Hapus Shortcut'
    }
}

function Show-ShortcutEditor([pscustomobject]$Existing=$null) {
    try {
        [xml]$dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Shortcut Manager"
        Width="650" Height="590"
        MinWidth="620" MinHeight="560"
        WindowStartupLocation="CenterOwner"
        Background="#F6F8FC"
        Foreground="#172033"
        FontFamily="Segoe UI"
        FontSize="13"
        ResizeMode="NoResize"
        ShowInTaskbar="False">
    <Window.Resources>
        <Style x:Key="FieldLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#344054"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="0,0,0,5"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="CaretBrush" Value="#172033"/>
            <Setter Property="SelectionBrush" Value="#BFDBFE"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="Padding" Value="8,6"/>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="Padding" Value="8,6"/>
        </Style>
        <Style x:Key="DlgButton" TargetType="Button">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#344054"/>
            <Setter Property="BorderBrush" Value="#D0D5DD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="15,8"/>
            <Setter Property="Margin" Value="4,0,0,0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style x:Key="DlgPrimary" TargetType="Button" BasedOn="{StaticResource DlgButton}">
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#2563EB"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="92"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="68"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#E4E7EC" BorderThickness="0,0,0,1">
            <Grid Margin="24,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="52"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Width="42" Height="42" CornerRadius="10" Background="#EFF6FF"
                        VerticalAlignment="Center" HorizontalAlignment="Left">
                    <TextBlock x:Name="PreviewBadge" Text="DIR" Foreground="#1D4ED8"
                               FontSize="11" FontWeight="Bold"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock x:Name="DialogTitle" Text="Tambah Shortcut"
                               Foreground="#172033" FontSize="21" FontWeight="Bold"/>
                    <TextBlock Text="Buat akses cepat ke folder, file, aplikasi, website, atau perintah PowerShell."
                               Foreground="#667085" FontSize="11" Margin="0,4,0,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="24,20,24,18">
                <Border Background="#FFFFFF" BorderBrush="#E4E7EC" BorderThickness="1"
                        CornerRadius="12" Padding="18">
                    <StackPanel>
                        <TextBlock Text="Nama Shortcut" Style="{StaticResource FieldLabel}"/>
                        <TextBox x:Name="NameBox" Height="38" VerticalContentAlignment="Center"/>

                        <Grid Margin="0,14,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0" Margin="0,0,7,0">
                                <TextBlock Text="Tipe" Style="{StaticResource FieldLabel}"/>
                                <ComboBox x:Name="TypeBox" Height="38" SelectedIndex="0">
                                    <ComboBoxItem Content="Folder"/>
                                    <ComboBoxItem Content="File"/>
                                    <ComboBoxItem Content="App"/>
                                    <ComboBoxItem Content="URL"/>
                                    <ComboBoxItem Content="PowerShell"/>
                                </ComboBox>
                            </StackPanel>

                            <StackPanel Grid.Column="1" Margin="7,0,0,0">
                                <TextBlock Text="Kategori" Style="{StaticResource FieldLabel}"/>
                                <ComboBox x:Name="CategoryBox" Height="38" IsEditable="True" Text="Custom"/>
                            </StackPanel>
                        </Grid>

                        <TextBlock Text="Target / Lokasi" Style="{StaticResource FieldLabel}" Margin="0,14,0,5"/>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox x:Name="TargetBox" Grid.Column="0" Height="38" VerticalContentAlignment="Center"/>
                            <Button x:Name="BrowseBtn" Grid.Column="1" Content="Jelajahi" Style="{StaticResource DlgButton}" Height="38"/>
                            <Button x:Name="TestBtn" Grid.Column="2" Content="Uji" Style="{StaticResource DlgButton}" Height="38"/>
                        </Grid>

                        <Border Background="#F8FAFC" BorderBrush="#EAECF0" BorderThickness="1"
                                CornerRadius="8" Padding="10" Margin="0,14,0,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="12"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Ellipse x:Name="ValidationDot" Width="8" Height="8" Fill="#98A2B3"
                                         VerticalAlignment="Center" HorizontalAlignment="Left"/>
                                <TextBlock x:Name="ValidationStatus" Grid.Column="1"
                                           Text="Masukkan target lalu tekan Test untuk memeriksa."
                                           Foreground="#667085" FontSize="11" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                    </StackPanel>
                </Border>

                <Border Background="#EFF6FF" BorderBrush="#DBEAFE" BorderThickness="1"
                        CornerRadius="10" Padding="12" Margin="0,12,0,0">
                    <TextBlock Foreground="#475467" FontSize="10.5" TextWrapping="Wrap"
                               Text="Folder/File/App: gunakan Browse. URL dapat ditulis seperti example.com dan akan otomatis menjadi https://example.com. PowerShell menerima perintah langsung."/>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#E4E7EC" BorderThickness="0,1,0,0">
            <Grid Margin="24,0">
                <TextBlock x:Name="FooterHint" Text="Semua perubahan disimpan setelah menekan Simpan."
                           Foreground="#98A2B3" FontSize="10" VerticalAlignment="Center"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <Button x:Name="CancelBtn" Content="Batal" Style="{StaticResource DlgButton}"/>
                    <Button x:Name="SaveBtn" Content="Simpan Shortcut" Style="{StaticResource DlgPrimary}"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

        $r = New-Object System.Xml.XmlNodeReader $dlgXaml
        $dlg = [Windows.Markup.XamlReader]::Load($r)
        $dlg.Owner = $window

        $NameBox = $dlg.FindName('NameBox')
        $TypeBox = $dlg.FindName('TypeBox')
        $TargetBox = $dlg.FindName('TargetBox')
        $CategoryBox = $dlg.FindName('CategoryBox')
        $BrowseBtn = $dlg.FindName('BrowseBtn')
        $TestBtn = $dlg.FindName('TestBtn')
        $SaveBtn = $dlg.FindName('SaveBtn')
        $CancelBtn = $dlg.FindName('CancelBtn')
        $PreviewBadge = $dlg.FindName('PreviewBadge')
        $DialogTitle = $dlg.FindName('DialogTitle')
        $ValidationDot = $dlg.FindName('ValidationDot')
        $ValidationStatus = $dlg.FindName('ValidationStatus')

        Apply-LanguageToElement $dlg

        # Fill reusable category suggestions.
        $knownCategories = @(
            $script:ShortcutStore |
            ForEach-Object { [string]$_.Category } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
        )
        foreach ($cat in $knownCategories) {
            [void]$CategoryBox.Items.Add($cat)
        }

        if ($Existing) {
            $DialogTitle.Text = 'Edit Shortcut'
            $NameBox.Text = [string]$Existing.Name
            $TargetBox.Text = [string]$Existing.Target
            $CategoryBox.Text = if ([string]::IsNullOrWhiteSpace([string]$Existing.Category)) { 'Custom' } else { [string]$Existing.Category }

            for ($i=0; $i -lt $TypeBox.Items.Count; $i++) {
                if ([string]$TypeBox.Items[$i].Content -eq [string]$Existing.Type) {
                    $TypeBox.SelectedIndex = $i
                    break
                }
            }
        }

        $updateTypeUi = {
            try {
                $type = [string]$TypeBox.SelectedItem.Content
                $PreviewBadge.Text = Get-TypeBadge $type
                $BrowseBtn.IsEnabled = ($type -in @('Folder','File','App'))
            } catch {}
        }

        $TypeBox.Add_SelectionChanged({
            & $updateTypeUi
            $ValidationDot.Fill = '#98A2B3'
            $ValidationStatus.Foreground = '#667085'
            $ValidationStatus.Text = 'Target berubah konteks. Tekan Test untuk memeriksa.'
        })

        $BrowseBtn.Add_Click({
            try {
                $type = [string]$TypeBox.SelectedItem.Content

                if ($type -eq 'Folder') {
                    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
                    $fb.Description = 'Pilih folder shortcut'
                    $fb.ShowNewFolderButton = $true

                    if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        $TargetBox.Text = $fb.SelectedPath
                        if ([string]::IsNullOrWhiteSpace($NameBox.Text)) {
                            $leaf = Split-Path $fb.SelectedPath -Leaf
                            if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $fb.SelectedPath }
                            $NameBox.Text = $leaf
                        }
                    }
                }
                elseif ($type -in @('File','App')) {
                    $of = New-Object Microsoft.Win32.OpenFileDialog
                    $of.Title = if ($type -eq 'App') { 'Pilih aplikasi' } else { 'Pilih file' }
                    $of.Filter = if ($type -eq 'App') {
                        'Aplikasi (*.exe;*.cmd;*.bat;*.com)|*.exe;*.cmd;*.bat;*.com|Semua File (*.*)|*.*'
                    } else {
                        'Semua File (*.*)|*.*'
                    }

                    if ($of.ShowDialog($dlg)) {
                        $TargetBox.Text = $of.FileName
                        if ([string]::IsNullOrWhiteSpace($NameBox.Text)) {
                            $NameBox.Text = [IO.Path]::GetFileNameWithoutExtension($of.FileName)
                        }
                    }
                }

                $ValidationDot.Fill = '#98A2B3'
                $ValidationStatus.Foreground = '#667085'
                $ValidationStatus.Text = 'Target dipilih. Tekan Test untuk memeriksa.'
            } catch {
                Show-Error $_.Exception.Message 'Browse'
            }
        })

        $TestBtn.Add_Click({
            try {
                $target = $TargetBox.Text.Trim()
                $type = [string]$TypeBox.SelectedItem.Content

                if ($type -eq 'URL' -and -not [string]::IsNullOrWhiteSpace($target) -and
                    $target -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                    $target = 'https://' + $target
                }

                $candidate = [pscustomobject]@{
                    Type = $type
                    Target = $target
                }

                if (Test-ShortcutTarget $candidate) {
                    $ValidationDot.Fill = '#22C55E'
                    $ValidationStatus.Foreground = '#15803D'
                    $ValidationStatus.Text = 'Target valid dan siap digunakan.'
                } else {
                    $ValidationDot.Fill = '#EF4444'
                    $ValidationStatus.Foreground = '#B42318'
                    $ValidationStatus.Text = 'Target belum valid atau tidak ditemukan.'
                }
            } catch {
                $ValidationDot.Fill = '#EF4444'
                $ValidationStatus.Foreground = '#B42318'
                $ValidationStatus.Text = $_.Exception.Message
            }
        })

        $CancelBtn.Tag = $dlg
        $CancelBtn.Add_Click({
            param($sender,$eventArgs)
            try {
                $dialog = $sender.Tag
                if ($null -eq $dialog) { return }
                $dialog.DialogResult = $false
                $dialog.Close()
            } catch {}
        })

        $SaveBtn.Tag = $dlg
        $SaveBtn.Add_Click({
            param($sender,$eventArgs)
            try {
                $dialog = $sender.Tag
                if ($null -eq $dialog) { return }
                $name = $NameBox.Text.Trim()
                $target = $TargetBox.Text.Trim()
                $category = $CategoryBox.Text.Trim()
                $type = [string]$TypeBox.SelectedItem.Content

                if ([string]::IsNullOrWhiteSpace($name)) {
                    Show-Error 'Nama shortcut wajib diisi.' 'Validasi'
                    return
                }

                if ([string]::IsNullOrWhiteSpace($target)) {
                    Show-Error 'Target wajib diisi.' 'Validasi'
                    return
                }

                if ($type -eq 'URL' -and $target -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                    $target = 'https://' + $target
                }

                if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Custom' }

                $dialog.Tag = [pscustomobject]@{
                    Name = $name
                    Type = $type
                    Target = $target
                    Category = $category
                    Icon = (Get-TypeBadge $type)
                }

                $dialog.DialogResult = $true
                $dialog.Close()
            } catch {
                Show-Error $_.Exception.Message 'Simpan Shortcut'
            }
        })

        & $updateTypeUi

        $ok = $dlg.ShowDialog()
        if ($ok -eq $true) {
            return $dlg.Tag
        }
        return $null
    } catch {
        Show-Error $_.Exception.Message 'Shortcut Editor'
        return $null
    }
}

function Add-ShortcutDialog {
    try {
        $result = Show-ShortcutEditor
        if ($null -eq $result) { return }

        $new = [pscustomobject][ordered]@{
            Id         = [guid]::NewGuid().ToString('D')
            Name       = [string]$result.Name
            Type       = [string]$result.Type
            Target     = [string]$result.Target
            Icon       = [string]$result.Icon
            Category   = [string]$result.Category
            Favorite   = $false
            Pinned     = $false
            OpenCount  = 0
            LastOpened = ''
        }

        # Add directly to the same in-memory collection displayed by the UI.
        $script:ShortcutStore = @($script:ShortcutStore) + @($new)

        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status "Shortcut '$($new.Name)' ditambahkan."
    } catch {
        Show-Error $_.Exception.Message 'Tambah Shortcut'
    }
}

function Edit-ShortcutDialog([string]$Id) {
    try {
        $existing = Get-ShortcutById $Id
        if ($null -eq $existing) {
            Show-Error ("Shortcut tidak ditemukan.`nID: {0}" -f $Id) 'Edit Shortcut'
            return
        }

        $result = Show-ShortcutEditor $existing
        if ($null -eq $result) { return }

        # Update the exact object that is already held by the UI/session.
        $existing.Name     = [string]$result.Name
        $existing.Type     = [string]$result.Type
        $existing.Target   = [string]$result.Target
        $existing.Icon     = [string]$result.Icon
        $existing.Category = [string]$result.Category

        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status "Shortcut '$($existing.Name)' diperbarui."
    } catch {
        Show-Error $_.Exception.Message 'Edit Shortcut'
    }
}

function New-ToolCard(
    [string]$Title,
    [string]$Subtitle,
    [string]$Icon,
    [scriptblock]$Action,
    [string]$ViewMode='Grid',
    [string]$Category=''
) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $window.Resources['ShortcutButton']

    switch ($ViewMode) {
        'List' {
            $available = 650
            try {
                if ($window.ActualWidth -gt 0) {
                    $available = [math]::Max(430, [math]::Min(760, $window.ActualWidth - 275))
                }
            } catch {}
            $btn.Width = $available
            $btn.Height = 84
            $btn.Margin = '4,4,4,5'
        }
        'Compact' {
            $btn.Width = 158
            $btn.Height = 88
            $btn.Margin = '5'
        }
        default {
            $btn.Width = 190
            $btn.Height = 104
            $btn.Margin = '6'
        }
    }

    $grid = New-Object System.Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height='*'}))

    $top = New-Object System.Windows.Controls.Grid
    $top.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='Auto'}))
    $top.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='*'}))

    $badge = New-Object System.Windows.Controls.Border
    $badge.Width = 36
    $badge.Height = 36
    $badge.Background = '#EFF6FF'
    $badge.CornerRadius = '9'
    $badge.Margin = '0,0,10,0'

    $tbIcon = New-Object System.Windows.Controls.TextBlock
    $tbIcon.Text = $Icon
    $tbIcon.Foreground = '#1D4ED8'
    $tbIcon.FontWeight = 'Bold'
    $tbIcon.FontSize = 9
    $tbIcon.HorizontalAlignment = 'Center'
    $tbIcon.VerticalAlignment = 'Center'
    $badge.Child = $tbIcon

    [System.Windows.Controls.Grid]::SetColumn($badge,0)
    [void]$top.Children.Add($badge)

    $titleStack = New-Object System.Windows.Controls.StackPanel
    $titleStack.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($titleStack,1)

    $tbTitle = New-Object System.Windows.Controls.TextBlock
    $tbTitle.Text = $Title
    $tbTitle.Foreground = '#172033'
    $tbTitle.FontSize = 13
    $tbTitle.FontWeight = 'SemiBold'
    $tbTitle.TextTrimming = 'CharacterEllipsis'

    $tbCategory = New-Object System.Windows.Controls.TextBlock
    $tbCategory.Text = $Category
    $tbCategory.Foreground = '#98A2B3'
    $tbCategory.FontSize = 9
    $tbCategory.Margin = '0,2,0,0'

    [void]$titleStack.Children.Add($tbTitle)
    [void]$titleStack.Children.Add($tbCategory)
    [void]$top.Children.Add($titleStack)

    [void]$grid.Children.Add($top)

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = $Subtitle
    $sub.Foreground = '#667085'
    $sub.FontSize = 9.5
    $sub.VerticalAlignment = 'Bottom'
    $sub.TextWrapping = if ($ViewMode -eq 'List') { 'NoWrap' } else { 'Wrap' }
    $sub.TextTrimming = 'CharacterEllipsis'
    $sub.Margin = '0,7,0,0'
    [System.Windows.Controls.Grid]::SetRow($sub,1)
    [void]$grid.Children.Add($sub)

    $btn.Content = $grid
    $btn.ToolTip = "$Title`n$Subtitle`n$Category"
    $btn.Add_Click($Action)
    return $btn
}

function Initialize-ToolCatalog {
    $catalogVar = Get-Variable -Name ToolCatalog -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $catalogVar -and $null -ne $catalogVar.Value -and @($catalogVar.Value).Count -gt 0) {
        return
    }

    $script:ToolCatalog = @(
        @{ T=(L 'File Explorer' 'File Explorer');       S=(L 'Buka Windows File Explorer' 'Open Windows File Explorer');                  I='DIR'; K='File & Folder'; C=(L 'File & Folder' 'File & Folder'); A={ Start-SafeProcess 'explorer.exe' } }
        @{ T=(L 'Downloads' 'Downloads');               S=(L 'Buka folder Downloads' 'Open the Downloads folder');                       I='DIR'; K='File & Folder'; C=(L 'File & Folder' 'File & Folder'); A={ $p=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'; Start-SafeProcess 'explorer.exe' @("`"$p`"") } }
        @{ T=(L 'Desktop' 'Desktop');                   S=(L 'Buka folder Desktop' 'Open the Desktop folder');                           I='DIR'; K='File & Folder'; C=(L 'File & Folder' 'File & Folder'); A={ $p=[Environment]::GetFolderPath('Desktop'); Start-SafeProcess 'explorer.exe' @("`"$p`"") } }
        @{ T=(L 'Documents' 'Documents');               S=(L 'Buka folder Documents' 'Open the Documents folder');                       I='DIR'; K='File & Folder'; C=(L 'File & Folder' 'File & Folder'); A={ $p=[Environment]::GetFolderPath('MyDocuments'); Start-SafeProcess 'explorer.exe' @("`"$p`"") } }
        @{ T=(L 'Recycle Bin' 'Recycle Bin');           S=(L 'Buka Recycle Bin' 'Open Recycle Bin');                                    I='BIN'; K='File & Folder'; C=(L 'File & Folder' 'File & Folder'); A={ Start-SafeProcess 'explorer.exe' @('shell:RecycleBinFolder') } }

        @{ T=(L 'Task Manager' 'Task Manager');         S=(L 'Monitor proses dan performa' 'Monitor processes and performance');          I='SYS'; K='System'; C=(L 'System' 'System'); A={ Start-SafeProcess 'taskmgr.exe' } }
        @{ T=(L 'Control Panel' 'Control Panel');       S=(L 'Panel kontrol klasik Windows' 'Classic Windows Control Panel');            I='SYS'; K='System'; C=(L 'System' 'System'); A={ Start-SafeProcess 'control.exe' } }
        @{ T=(L 'Windows Settings' 'Windows Settings'); S=(L 'Pengaturan Windows' 'Windows settings');                                   I='SYS'; K='System'; C=(L 'System' 'System'); A={ Start-SafeProcess 'explorer.exe' @('ms-settings:') 'control.exe' } }
        @{ T=(L 'System Information' 'System Information'); S=(L 'Informasi hardware dan software' 'Hardware and software information'); I='SYS'; K='System'; C=(L 'System' 'System'); A={ Start-SafeProcess 'msinfo32.exe' } }
        @{ T=(L 'Resource Monitor' 'Resource Monitor'); S=(L 'CPU, RAM, disk, dan network detail' 'Detailed CPU, RAM, disk, and network usage'); I='SYS'; K='System'; C=(L 'System' 'System'); A={ Start-SafeProcess 'resmon.exe' } }

        @{ T=(L 'Services' 'Services');                 S=(L 'Kelola Windows Services' 'Manage Windows Services');                       I='MMC'; K='Management'; C=(L 'Management' 'Management'); A={ Start-SafeProcess 'services.msc' } }
        @{ T=(L 'Task Scheduler' 'Task Scheduler');     S=(L 'Kelola Scheduled Tasks' 'Manage Scheduled Tasks');                        I='MMC'; K='Management'; C=(L 'Management' 'Management'); A={ Start-SafeProcess 'taskschd.msc' } }
        @{ T=(L 'Device Manager' 'Device Manager');     S=(L 'Kelola perangkat hardware' 'Manage hardware devices');                    I='MMC'; K='Management'; C=(L 'Management' 'Management'); A={ Start-SafeProcess 'devmgmt.msc' } }
        @{ T=(L 'Disk Management' 'Disk Management');   S=(L 'Kelola partisi dan disk' 'Manage disks and partitions');                  I='MMC'; K='Management'; C=(L 'Management' 'Management'); A={ Start-SafeProcess 'diskmgmt.msc' } }
        @{ T=(L 'Event Viewer' 'Event Viewer');         S=(L 'Log aplikasi, sistem, dan keamanan' 'Application, system, and security logs'); I='LOG'; K='Management'; C=(L 'Management' 'Management'); A={ Start-SafeProcess 'eventvwr.msc' } }
        @{ T=(L 'Registry Editor' 'Registry Editor');   S=(L 'Buka Registry Editor' 'Open Registry Editor');                            I='REG'; K='Management'; C=(L 'Management' 'Management'); A={ Start-SafeProcess 'regedit.exe' } }

        @{ T=(L 'Network Connections' 'Network Connections'); S=(L 'Adapter dan koneksi jaringan' 'Network adapters and connections'); I='NET'; K='Network'; C=(L 'Network' 'Network'); A={ Start-SafeProcess 'control.exe' @('ncpa.cpl') } }

        @{ T=(L 'PowerShell' 'PowerShell');             S=(L 'Buka Windows PowerShell' 'Open Windows PowerShell');                       I='PS';  K='Terminal'; C=(L 'Terminal' 'Terminal'); A={ Start-SafeProcess 'powershell.exe' } }
        @{ T=(L 'Command Prompt' 'Command Prompt');     S=(L 'Buka Command Prompt' 'Open Command Prompt');                              I='CMD'; K='Terminal'; C=(L 'Terminal' 'Terminal'); A={ Start-SafeProcess 'cmd.exe' } }

        @{ T=(L 'Export Shortcut' 'Export Shortcuts');  S=(L 'Simpan semua shortcut ke JSON' 'Save all shortcuts to JSON');              I='EXP'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Export-ShortcutData } }
        @{ T=(L 'Import Shortcut' 'Import Shortcuts');  S=(L 'Gabung atau pulihkan dari JSON' 'Merge or restore from JSON');              I='IMP'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Import-ShortcutData } }
        @{ T=(L 'Restore LKG' 'Restore LKG');           S=(L 'Pulihkan Last Known Good dari Registry' 'Restore Last Known Good from Registry'); I='BKP'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Restore-LastKnownGood } }
        @{ T=(L 'Reset Shortcut' 'Reset Shortcuts');    S=(L 'Kembalikan menu shortcut bawaan' 'Restore default shortcuts');             I='RST'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Reset-ShortcutDefaults } }
        @{ T=(L 'Desktop Shortcut' 'Desktop Shortcut'); S=(L 'Buat shortcut aplikasi di Desktop' 'Create an application shortcut on Desktop'); I='LNK'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Create-DesktopAppShortcut } }
        @{ T=(L 'Registry Data' 'Registry Data');       S=(L 'Buka Registry dan salin lokasi data' 'Open Registry and copy the data location'); I='REG'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Open-AppRegistry } }
        @{ T=(L 'Backup Full Config' 'Backup Full Config'); S=(L 'Backup shortcut dan seluruh Settings' 'Back up shortcuts and all Settings'); I='BKP'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Export-AppConfiguration } }
        @{ T=(L 'Restore Full Config' 'Restore Full Config'); S=(L 'Restore shortcut dan seluruh Settings' 'Restore shortcuts and all Settings'); I='RST'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Import-AppConfiguration } }
        @{ T=(L 'Self Diagnostics' 'Self Diagnostics'); S=(L 'Periksa storage, tray, hotkey, dan runspace' 'Check storage, tray, hotkey, and runspace'); I='CHK'; K='Data & Recovery'; C=(L 'Data & Pemulihan' 'Data & Recovery'); A={ Show-SelfDiagnostics } }
    )
}

function Refresh-ToolViews {
    Initialize-ToolCatalog

    $search = ''
    if ($script:TxtToolSearch) {
        $search = ([string]$script:TxtToolSearch.Text).Trim().ToLowerInvariant()
    }

    $category = Get-ComboContent $script:CmbToolCategory 'Semua Kategori'
    $viewMode = Get-ComboContent $script:CmbToolView 'Grid'

    $filtered = @(
        $script:ToolCatalog | Where-Object {
            $okCategory = ($category -eq 'Semua Kategori' -or [string]$_.K -eq $category)
            $hay = ("{0} {1} {2} {3}" -f $_.T,$_.S,$_.I,$_.C).ToLowerInvariant()
            $okSearch = ([string]::IsNullOrWhiteSpace($search) -or $hay.Contains($search))
            $okCategory -and $okSearch
        }
    )

    $script:ToolsPanel.Children.Clear()
    foreach ($tool in $filtered) {
        [void]$script:ToolsPanel.Children.Add(
            (New-ToolCard $tool.T $tool.S $tool.I $tool.A $viewMode $tool.C)
        )
    }

    if ($filtered.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = (L 'Tidak ada Windows Tool yang cocok dengan filter.' 'No Windows Tools match the current filter.')
        $empty.Foreground = '#667085'
        $empty.FontSize = 13
        $empty.Margin = '8,16'
        [void]$script:ToolsPanel.Children.Add($empty)
    }

    Set-Status ((L "Windows Tools: {0} dari {1}" "Windows Tools: {0} of {1}") -f $filtered.Count, @($script:ToolCatalog).Count)
}

function Build-Tools {
    Initialize-ToolCatalog
    Refresh-ToolViews
}

function Refresh-GlobalSearch {
    Initialize-ToolCatalog

    $query = ''
    if ($script:TxtGlobalSearch) {
        $query = ([string]$script:TxtGlobalSearch.Text).Trim().ToLowerInvariant()
    }

    if ($script:TxtGlobalSearchHint) {
        $script:TxtGlobalSearchHint.Visibility = if ([string]::IsNullOrWhiteSpace($query)) { 'Visible' } else { 'Collapsed' }
    }

    if ([string]::IsNullOrWhiteSpace($query)) {
        if ($script:PageGlobalSearch.Visibility -eq 'Visible') {
            $returnPage = if ([string]::IsNullOrWhiteSpace([string]$script:LastNonSearchPage)) { 'Dashboard' } else { $script:LastNonSearchPage }
            Show-Page $returnPage
        }
        return
    }

    $shortcutMatches = @(
        $script:ShortcutStore | Where-Object {
            $hay = ("{0} {1} {2} {3}" -f $_.Name,$_.Type,$_.Category,$_.Target).ToLowerInvariant()
            $hay.Contains($query)
        }
    )

    $toolMatches = @(
        $script:ToolCatalog | Where-Object {
            $hay = ("{0} {1} {2} {3}" -f $_.T,$_.S,$_.I,$_.C).ToLowerInvariant()
            $hay.Contains($query)
        }
    )

    Show-Page 'Search'

    $script:GlobalShortcutPanel.Children.Clear()
    foreach ($item in $shortcutMatches) {
        $card = New-ShortcutCard $item
        if ($null -ne $card) {
            $card.Width = 178
            $card.Height = 98
            [void]$script:GlobalShortcutPanel.Children.Add($card)
        }
    }

    if ($shortcutMatches.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = (L 'Tidak ada shortcut.' 'No shortcuts found.')
        $empty.Foreground = '#98A2B3'
        $empty.Margin = '6,8,0,12'
        [void]$script:GlobalShortcutPanel.Children.Add($empty)
    }

    $script:GlobalToolsPanel.Children.Clear()
    foreach ($tool in $toolMatches) {
        [void]$script:GlobalToolsPanel.Children.Add(
            (New-ToolCard $tool.T $tool.S $tool.I $tool.A 'Grid' $tool.C)
        )
    }

    if ($toolMatches.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = (L 'Tidak ada Windows Tool.' 'No Windows Tools found.')
        $empty.Foreground = '#98A2B3'
        $empty.Margin = '6,8,0,12'
        [void]$script:GlobalToolsPanel.Children.Add($empty)
    }

    $total = $shortcutMatches.Count + $toolMatches.Count
    if ((Get-AppLanguage) -eq 'en') {
        $script:TxtGlobalResultCount.Text = "$total results for '$($script:TxtGlobalSearch.Text.Trim())'"
    } else {
        $script:TxtGlobalResultCount.Text = "$total hasil untuk '$($script:TxtGlobalSearch.Text.Trim())'"
    }
    if ((Get-AppLanguage) -eq 'en') {
        Set-Status "Global Search: $total results"
    } else {
        Set-Status "Global Search: $total hasil"
    }
}

function Initialize-BackgroundRunspacePool {
    if ($null -ne $script:BackgroundRunspacePool) { return }

    try {
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1,2)
        $pool.ApartmentState = [System.Threading.ApartmentState]::MTA
        $pool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $pool.Open()
        $script:BackgroundRunspacePool = $pool
    }
    catch {
        $script:BackgroundRunspacePool = $null
        throw
    }
}

function Dispose-BackgroundRunspacePool {
    try {
        if ($null -ne $script:SystemInfoPowerShell) {
            try { $script:SystemInfoPowerShell.Stop() } catch {}
            try { $script:SystemInfoPowerShell.Dispose() } catch {}
        }
    } catch {}

    try {
        if ($null -ne $script:SystemMonitorPowerShell) {
            try { $script:SystemMonitorPowerShell.Stop() } catch {}
            try { $script:SystemMonitorPowerShell.Dispose() } catch {}
        }
    } catch {}

    $script:SystemInfoPowerShell = $null
    $script:SystemInfoAsyncResult = $null
    $script:SystemMonitorPowerShell = $null
    $script:SystemMonitorAsyncResult = $null

    try {
        if ($null -ne $script:BackgroundRunspacePool) {
            $script:BackgroundRunspacePool.Close()
            $script:BackgroundRunspacePool.Dispose()
        }
    } catch {}

    $script:BackgroundRunspacePool = $null
}

function Set-SystemInfoControls([object]$s) {
    if ($null -eq $s) { return }

    $script:SysComputer.Text = [string]$s.Computer
    $script:SysUser.Text = [string]$s.User
    $script:SysWindows.Text = [string]$s.Windows
    $script:SysVersion.Text = [string]$s.Version
    $script:SysCPU.Text = [string]$s.CPU
    $script:SysRAM.Text = [string]$s.RAM
    $script:SysUptime.Text = [string]$s.Uptime
    $script:SysDisks.ItemsSource = @($s.Disks)
}

function Set-SystemLoading([bool]$Loading) {
    $script:SystemInfoLoading = $Loading

    if ($null -ne $script:SystemLoadingPanel) {
        $script:SystemLoadingPanel.Visibility = if ($Loading) { 'Visible' } else { 'Collapsed' }
    }

    if ($null -ne $script:BtnRefreshSystem) {
        $script:BtnRefreshSystem.IsEnabled = (-not $Loading)
        $script:BtnRefreshSystem.Content = if ($Loading) { 'Memuat...' } else { 'Refresh' }
    }
}

function Start-SystemInfoBackgroundLoad([switch]$Force) {
    try {
        if (-not $Force -and $null -ne $script:SystemInfoCache) {
            Set-SystemInfoControls $script:SystemInfoCache
            Set-SystemLoading $false
            Set-Status 'System Info siap.'
            return
        }

        if ($null -ne $script:SystemInfoAsyncResult) {
            try {
                if (-not $script:SystemInfoAsyncResult.IsCompleted) {
                    Set-SystemLoading $true
                    return
                }
            } catch {}
        }

        Initialize-BackgroundRunspacePool
        Set-SystemLoading $true
        Set-Status 'Memuat System Info melalui background runspace...'

        if ($null -ne $script:SystemInfoPowerShell) {
            try { $script:SystemInfoPowerShell.Dispose() } catch {}
        }

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $script:BackgroundRunspacePool

        $staticScript = @'
try {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | Sort-Object DeviceID
    } catch {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
        $disk = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | Sort-Object DeviceID
    }

    $ramTotal = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB,1)
    $ramFree = [math]::Round([double]$os.FreePhysicalMemory * 1KB / 1GB,1)
    $ramUsed = [math]::Round($ramTotal - $ramFree,1)
    $ramPct = if ($ramTotal -gt 0) {
        [math]::Round(($ramUsed / $ramTotal) * 100)
    } else { 0 }

    $lastBoot = $os.LastBootUpTime
    if ($lastBoot -is [string]) {
        try {
            $lastBoot = [Management.ManagementDateTimeConverter]::ToDateTime($lastBoot)
        } catch {}
    }

    $uptime = (Get-Date) - [datetime]$lastBoot
    $uptimeText = '{0} hari {1} jam {2} menit' -f `
        [int]$uptime.TotalDays,$uptime.Hours,$uptime.Minutes

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        User = $env:USERNAME
        Windows = [string]$os.Caption
        Version = [string]$os.Version
        CPU = [string]$cpu.Name
        RAM = "$ramUsed GB / $ramTotal GB ($ramPct%)"
        Uptime = $uptimeText
        Disks = @(
            $disk | ForEach-Object {
                $total = [math]::Round([double]$_.Size / 1GB,1)
                $free = [math]::Round([double]$_.FreeSpace / 1GB,1)
                "$($_.DeviceID)    $free GB bebas / $total GB"
            }
        )
        LoadError = ''
    }
}
catch {
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        User = $env:USERNAME
        Windows = 'Tidak tersedia'
        Version = '-'
        CPU = '-'
        RAM = '-'
        Uptime = '-'
        Disks = @('-')
        LoadError = $_.Exception.Message
    }
}
'@

        [void]$ps.AddScript($staticScript)
        $script:SystemInfoPowerShell = $ps
        $script:SystemInfoAsyncResult = $ps.BeginInvoke()

        if ($null -eq $script:SystemInfoPollTimer) {
            $script:SystemInfoPollTimer = New-Object Windows.Threading.DispatcherTimer
            $script:SystemInfoPollTimer.Interval = [TimeSpan]::FromMilliseconds(120)

            $script:SystemInfoPollTimer.Add_Tick({
                try {
                    if ($null -eq $script:SystemInfoAsyncResult -or
                        $null -eq $script:SystemInfoPowerShell) {
                        return
                    }

                    if (-not $script:SystemInfoAsyncResult.IsCompleted) { return }

                    $psLocal = $script:SystemInfoPowerShell
                    $asyncLocal = $script:SystemInfoAsyncResult
                    $script:SystemInfoPowerShell = $null
                    $script:SystemInfoAsyncResult = $null

                    $result = $null
                    try {
                        $result = $psLocal.EndInvoke($asyncLocal) | Select-Object -Last 1
                    }
                    finally {
                        $psLocal.Dispose()
                    }

                    if ($null -ne $result) {
                        $script:SystemInfoCache = $result
                        Set-SystemInfoControls $result

                        $loadError = ''
                        try {
                            $prop = $result.PSObject.Properties['LoadError']
                            if ($null -ne $prop) {
                                $loadError = [string]$prop.Value
                            }
                        } catch {}

                        if ([string]::IsNullOrWhiteSpace($loadError)) {
                            Set-Status 'System Info berhasil diperbarui.'
                        } else {
                            Set-Status ('System Info dimuat dengan peringatan: ' + $loadError)
                        }
                    } else {
                        Set-Status 'System Info gagal dimuat.'
                    }

                    Set-SystemLoading $false
                }
                catch {
                    Set-SystemLoading $false
                    Set-Status ('System Info error: ' + $_.Exception.Message)

                    try {
                        if ($null -ne $script:SystemInfoPowerShell) {
                            $script:SystemInfoPowerShell.Dispose()
                        }
                    } catch {}

                    $script:SystemInfoPowerShell = $null
                    $script:SystemInfoAsyncResult = $null
                }
            })

            $script:SystemInfoPollTimer.Start()
        }
    }
    catch {
        Set-SystemLoading $false
        Show-Error $_.Exception.Message 'System Info'
    }
}

function Format-Rate([double]$BytesPerSecond) {
    if ($BytesPerSecond -ge 1GB) {
        return ('{0:N1} GB/s' -f ($BytesPerSecond / 1GB))
    }
    elseif ($BytesPerSecond -ge 1MB) {
        return ('{0:N1} MB/s' -f ($BytesPerSecond / 1MB))
    }
    elseif ($BytesPerSecond -ge 1KB) {
        return ('{0:N0} KB/s' -f ($BytesPerSecond / 1KB))
    }

    return ('{0:N0} B/s' -f $BytesPerSecond)
}

function Update-SystemMonitorControls([object]$Metrics) {
    if ($null -eq $Metrics) { return }

    $cpu = 0.0
    $ram = 0.0
    $rx = 0.0
    $tx = 0.0

    try { $cpu = [math]::Max(0,[math]::Min(100,[double]$Metrics.CPU)) } catch {}
    try { $ram = [math]::Max(0,[math]::Min(100,[double]$Metrics.RAM)) } catch {}
    try { $rx = [double]$Metrics.Rx } catch {}
    try { $tx = [double]$Metrics.Tx } catch {}

    $script:TxtLiveCPU.Text = ('{0:N0} %' -f $cpu)
    $script:BarLiveCPU.Value = $cpu

    $script:TxtLiveRAM.Text = ('{0:N0} %' -f $ram)
    $script:BarLiveRAM.Value = $ram

    $script:TxtLiveNetwork.Text = ('↓ {0}   ↑ {1}' -f (Format-Rate $rx),(Format-Rate $tx))
    $script:TxtLiveMonitorStatus.Text = 'LIVE · 2s'
    $script:TxtLiveMonitorStatus.Foreground = '#15803D'
}

function Invoke-SystemMonitorSample {
    if (-not $script:SystemMonitorEnabled) { return }
    if ($script:PageSystem.Visibility -ne 'Visible') { return }

    try {
        if ($null -ne $script:SystemMonitorAsyncResult -and
            $null -ne $script:SystemMonitorPowerShell) {

            if ($script:SystemMonitorAsyncResult.IsCompleted) {
                $psLocal = $script:SystemMonitorPowerShell
                $asyncLocal = $script:SystemMonitorAsyncResult
                $script:SystemMonitorPowerShell = $null
                $script:SystemMonitorAsyncResult = $null

                try {
                    $result = $psLocal.EndInvoke($asyncLocal) | Select-Object -Last 1
                    if ($null -ne $result) {
                        Update-SystemMonitorControls $result
                    }
                }
                finally {
                    $psLocal.Dispose()
                }
            } else {
                return
            }
        }

        Initialize-BackgroundRunspacePool

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $script:BackgroundRunspacePool

        $monitorScript = @'
$cpuPct = 0.0
$ramPct = 0.0
$rx = 0.0
$tx = 0.0

try {
    try {
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
    } catch {
        $cpu = Get-WmiObject Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
    }
    $cpuPct = [double]$cpu.PercentProcessorTime
} catch {}

try {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    } catch {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
    }

    $total = [double]$os.TotalVisibleMemorySize
    $free = [double]$os.FreePhysicalMemory

    if ($total -gt 0) {
        $ramPct = (($total - $free) / $total) * 100
    }
} catch {}

try {
    try {
        $nets = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
    } catch {
        $nets = Get-WmiObject Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
    }

    foreach ($n in @($nets)) {
        if ([string]$n.Name -eq '_Total') { continue }
        try { $rx += [double]$n.BytesReceivedPersec } catch {}
        try { $tx += [double]$n.BytesSentPersec } catch {}
    }
} catch {}

[pscustomobject]@{
    CPU = [math]::Round($cpuPct,1)
    RAM = [math]::Round($ramPct,1)
    Rx = [math]::Round($rx,0)
    Tx = [math]::Round($tx,0)
}
'@

        [void]$ps.AddScript($monitorScript)
        $script:SystemMonitorPowerShell = $ps
        $script:SystemMonitorAsyncResult = $ps.BeginInvoke()
    }
    catch {
        $script:TxtLiveMonitorStatus.Text = 'Monitor error'
        $script:TxtLiveMonitorStatus.Foreground = '#B42318'

        try {
            if ($null -ne $script:SystemMonitorPowerShell) {
                $script:SystemMonitorPowerShell.Dispose()
            }
        } catch {}

        $script:SystemMonitorPowerShell = $null
        $script:SystemMonitorAsyncResult = $null
    }
}

function Start-SystemMonitor {
    $script:SystemMonitorEnabled = $true

    if ($null -eq $script:SystemMonitorTimer) {
        $script:SystemMonitorTimer = New-Object Windows.Threading.DispatcherTimer
        $script:SystemMonitorTimer.Interval = [TimeSpan]::FromSeconds(2)
        $script:SystemMonitorTimer.Add_Tick({
            Invoke-SystemMonitorSample
        })
    }

    if (-not $script:SystemMonitorTimer.IsEnabled) {
        $script:SystemMonitorTimer.Start()
    }

    $script:TxtLiveMonitorStatus.Text = 'Starting...'
    $script:TxtLiveMonitorStatus.Foreground = '#667085'
    Invoke-SystemMonitorSample
}

function Stop-SystemMonitor {
    $script:SystemMonitorEnabled = $false

    try {
        if ($null -ne $script:SystemMonitorTimer) {
            $script:SystemMonitorTimer.Stop()
        }
    } catch {}

    if ($null -ne $script:TxtLiveMonitorStatus) {
        $script:TxtLiveMonitorStatus.Text = 'Standby'
        $script:TxtLiveMonitorStatus.Foreground = '#667085'
    }
}

function Show-SystemInfoPage {
    if ($null -ne $script:SystemInfoCache) {
        Set-SystemInfoControls $script:SystemInfoCache
        Set-SystemLoading $false
        Set-Status 'System Info siap.'
    } else {
        Start-SystemInfoBackgroundLoad
    }

    Start-SystemMonitor
}

function Refresh-SystemInfo {
    Start-SystemInfoBackgroundLoad -Force
    Invoke-SystemMonitorSample
}

function Import-DroppedShortcuts([string[]]$Paths) {
    try {
        $pathsToAdd = @(
            $Paths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        )

        if ($pathsToAdd.Count -eq 0) { return }

        $existingTargets = @{}
        foreach ($existing in @($script:ShortcutStore)) {
            if ($null -eq $existing) { continue }
            $key = ([string]$existing.Target).Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $existingTargets[$key] = $true
            }
        }

        $newItems = @()
        $skipped = 0

        foreach ($path in $pathsToAdd) {
            if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
                $skipped++
                continue
            }

            $key = ([string]$path).Trim().ToLowerInvariant()
            if ($existingTargets.ContainsKey($key)) {
                $skipped++
                continue
            }

            $type = 'File'
            if (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue) {
                $type = 'Folder'
            } else {
                $ext = [IO.Path]::GetExtension($path)
                if ($ext -match '^(?i)\.(exe|com|cmd|bat|msc|cpl)$') {
                    $type = 'App'
                }
            }

            $name = ''
            try {
                if ($type -eq 'Folder') {
                    $name = Split-Path -Path $path -Leaf
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = $path }
                } else {
                    $name = [IO.Path]::GetFileNameWithoutExtension($path)
                }
            } catch {
                $name = $path
            }

            $newItems += [pscustomobject][ordered]@{
                Id         = [guid]::NewGuid().ToString('D')
                Name       = $name
                Type       = $type
                Target     = $path
                Icon       = Get-TypeBadge $type
                Category   = 'Drag & Drop'
                Favorite   = $false
                Pinned     = $false
                OpenCount  = 0
                LastOpened = ''
            }
            $existingTargets[$key] = $true
        }

        if ($newItems.Count -eq 0) {
            Show-Info 'Tidak ada item baru untuk ditambahkan. File/folder mungkin sudah terdaftar atau tidak valid.' 'Drag & Drop'
            return
        }

        $previewNames = @($newItems | Select-Object -First 6 | ForEach-Object { '• ' + $_.Name })
        $preview = [string]::Join("`n", $previewNames)
        if ($newItems.Count -gt 6) {
            $preview += "`n• ... dan $($newItems.Count - 6) item lainnya"
        }

        $message = "Tambahkan $($newItems.Count) shortcut dari Drag & Drop?`n`n$preview"
        if ($skipped -gt 0) {
            $message += "`n`n$skipped item dilewati karena duplikat/tidak valid."
        }

        if (-not (Ask-Confirm $message 'Drag & Drop')) { return }

        $script:ShortcutStore = @($script:ShortcutStore) + @($newItems)
        Save-ShortcutStore
        Refresh-ShortcutViews
        Set-Status "$($newItems.Count) shortcut berhasil ditambahkan melalui Drag & Drop."
    } catch {
        Show-Error $_.Exception.Message 'Drag & Drop'
    }
}

function Invoke-OnUI([scriptblock]$Action) {
    try {
        if ($null -eq $window) { return }
        if ($window.Dispatcher.CheckAccess()) {
            & $Action
        } else {
            [void]$window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Normal,
                $Action
            )
        }
    } catch {}
}

function Show-MainWindow {
    try {
        if ($null -ne $script:WindowLogoSource) {
            try { $window.Icon = $script:WindowLogoSource } catch {}
        }

        $window.ShowInTaskbar = $true
        $window.Show()

        if ($window.WindowState -eq 'Minimized') {
            $window.WindowState = 'Normal'
        }

        $window.Activate() | Out-Null
        $window.Topmost = $true
        $window.Topmost = $false
        $window.Focus() | Out-Null
    } catch {}
}

function Hide-ToTray([switch]$ShowBalloon) {
    try {
        $trayReady = Initialize-SystemTray

        if (-not $trayReady -or $null -eq $script:TrayIcon) {
            throw 'System Tray tidak dapat diinisialisasi. Jendela aplikasi tidak akan disembunyikan.'
        }

        if (-not $script:TrayIcon.Visible) {
            $script:TrayIcon.Visible = $true
        }

        # Only hide after tray availability has been verified.
        $window.ShowInTaskbar = $false
        $window.Hide()

        if ($ShowBalloon) {
            try {
                $script:TrayIcon.BalloonTipTitle = 'Windows Shortcut Control'
                $script:TrayIcon.BalloonTipText = (L 'Aplikasi tetap berjalan di System Tray.' 'The application is still running in System Tray.')
                $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
                $script:TrayIcon.ShowBalloonTip(1800)
            } catch {}
        }

        Set-Status 'Berjalan di System Tray.'
        return $true
    }
    catch {
        # Safety fallback: a tray failure must never make the application
        # invisible and inaccessible.
        try { Show-MainWindow } catch {}
        Set-Status 'System Tray gagal. Aplikasi tetap ditampilkan.'
        return $false
    }
}

function Exit-Application {
    try {
        $script:AllowWindowClose = $true
        $window.ShowInTaskbar = $true
        $window.Close()
    } catch {}
}

function New-RoundedRectanglePath {
    param(
        [single]$X,
        [single]$Y,
        [single]$Width,
        [single]$Height,
        [single]$Radius
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2

    $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
    $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
    $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()

    return $path
}

function Initialize-AppLogo {
    if ($null -ne $script:TrayAppIcon -and $null -ne $script:WindowLogoSource) {
        return $true
    }

    try {
        $bitmap = New-Object System.Drawing.Bitmap 64,64
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

        try {
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.Clear([System.Drawing.Color]::Transparent)

            $bgPath = New-RoundedRectanglePath 4 4 56 56 14
            try {
                $blueBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(37,99,235))
                try {
                    $graphics.FillPath($blueBrush, $bgPath)
                } finally {
                    $blueBrush.Dispose()
                }
            } finally {
                $bgPath.Dispose()
            }

            # Window/control grid.
            $whitePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White),4
            try {
                $whitePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $whitePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $whitePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

                $graphics.DrawRectangle($whitePen, 15, 16, 30, 25)
                $graphics.DrawLine($whitePen, 30, 16, 30, 41)
                $graphics.DrawLine($whitePen, 15, 28.5, 45, 28.5)

                # Shortcut arrow: key identity for Windows Shortcut Control.
                $graphics.DrawLine($whitePen, 34, 49, 50, 33)
                $graphics.DrawLine($whitePen, 41, 33, 50, 33)
                $graphics.DrawLine($whitePen, 50, 33, 50, 42)
            } finally {
                $whitePen.Dispose()
            }
        }
        finally {
            $graphics.Dispose()
        }

        $hIcon = $bitmap.GetHicon()
        try {
            $tempIcon = [System.Drawing.Icon]::FromHandle($hIcon)
            $script:TrayAppIcon = [System.Drawing.Icon]$tempIcon.Clone()
        }
        finally {
            # BitmapSource is independent after Freeze; the cloned Icon remains
            # alive in script scope for the lifetime of NotifyIcon.
            try {
                $script:WindowLogoSource =
                    [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                        $hIcon,
                        [System.Windows.Int32Rect]::Empty,
                        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(32,32)
                    )
                $script:WindowLogoSource.Freeze()
            } catch {}

            $bitmap.Dispose()
        }

        if ($null -ne $script:WindowLogoSource) {
            try { $window.Icon = $script:WindowLogoSource } catch {}
        }

        return ($null -ne $script:TrayAppIcon)
    }
    catch {
        $script:TrayAppIcon = $null
        $script:WindowLogoSource = $null
        return $false
    }
}

function Dispose-AppLogo {
    try {
        if ($null -ne $script:TrayAppIcon) {
            $script:TrayAppIcon.Dispose()
            $script:TrayAppIcon = $null
        }
    } catch {}

    $script:WindowLogoSource = $null
}

function Start-TrayKeepAlive {
    if ($null -eq $script:TrayKeepAliveTimer) {
        $script:TrayKeepAliveTimer = New-Object Windows.Threading.DispatcherTimer
        $script:TrayKeepAliveTimer.Interval = [TimeSpan]::FromSeconds(5)

        $script:TrayKeepAliveTimer.Add_Tick({
            try {
                # NotifyIcon must stay strongly referenced and visible for the
                # entire lifetime of the process.
                if ($null -eq $script:TrayIcon) {
                    [void](Initialize-SystemTray)
                }
                elseif (-not $script:TrayIcon.Visible) {
                    $script:TrayIcon.Visible = $true
                }
            } catch {}
        })
    }

    if (-not $script:TrayKeepAliveTimer.IsEnabled) {
        $script:TrayKeepAliveTimer.Start()
    }
}

function Initialize-SystemTray {
    try {
        if ($null -ne $script:TrayIcon) {
            try {
                if ($script:TrayIcon.Visible) { return $true }
            } catch {}

            try { $script:TrayIcon.Dispose() } catch {}
            $script:TrayIcon = $null
        }

        if (-not (Initialize-AppLogo)) {
            return $false
        }

        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Text = 'Windows Shortcut Control'
        $tray.Icon = $script:TrayAppIcon

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System

        $miOpen = $menu.Items.Add((L 'Buka Windows Shortcut Control' 'Open Windows Shortcut Control'))
        $miOpen.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
            }
        })

        $miPalette = $menu.Items.Add('Command Palette')
        $miPalette.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
                Show-CommandPalette
            }
        })

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $miDashboard = $menu.Items.Add('Dashboard')
        $miDashboard.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
                Show-Page 'Dashboard'
            }
        })

        $miShortcuts = $menu.Items.Add((L 'Shortcut' 'Shortcuts'))
        $miShortcuts.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
                Show-Page 'Shortcuts'
            }
        })

        $miTools = $menu.Items.Add((L 'Alat Windows' 'Windows Tools'))
        $miTools.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
                Show-Page 'Tools'
            }
        })

        $miSystem = $menu.Items.Add((L 'Info Sistem' 'System Info'))
        $miSystem.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
                Show-Page 'System'
            }
        })

        $miSettings = $menu.Items.Add((L 'Pengaturan' 'Settings'))
        $miSettings.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
                Show-Page 'Settings'
            }
        })

        $miAbout = $menu.Items.Add((L 'Tentang' 'About'))
        $miAbout.Add_Click({
            Invoke-OnUI {
                Show-MainWindow
                Show-AboutDialog
            }
        })

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $miExit = $menu.Items.Add((L 'Keluar' 'Exit'))
        $miExit.Add_Click({
            Invoke-OnUI {
                Exit-Application
            }
        })

        $tray.ContextMenuStrip = $menu

        $tray.Add_DoubleClick({
            Invoke-OnUI {
                Show-MainWindow
            }
        })

        # Assign only after the menu is fully built.
        $script:TrayMenu = $menu
        $script:TrayIcon = $tray
        $script:TrayIcon.Icon = $script:TrayAppIcon
        $script:TrayIcon.Visible = $true

        return $true
    }
    catch {
        try {
            if ($null -ne $script:TrayIcon) {
                $script:TrayIcon.Visible = $false
                $script:TrayIcon.Dispose()
            }
        } catch {}

        try {
            if ($null -ne $script:TrayMenu) {
                $script:TrayMenu.Dispose()
            }
        } catch {}

        $script:TrayIcon = $null
        $script:TrayMenu = $null
        return $false
    }
}

function Dispose-SystemTray {
    try {
        if ($null -ne $script:TrayIcon) {
            $script:TrayIcon.Visible = $false
            $script:TrayIcon.Dispose()
            $script:TrayIcon = $null
        }
    } catch {}

    try {
        if ($null -ne $script:TrayMenu) {
            $script:TrayMenu.Dispose()
            $script:TrayMenu = $null
        }
    } catch {}
}

function Initialize-HotkeyInterop {
    if ('WindowsShortcutControlNative' -as [type]) { return }

    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WindowsShortcutControlNative
{
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
'@
}

function Unregister-GlobalHotkey {
    try {
        if ($script:GlobalHotkeyRegistered -and $null -ne $script:GlobalHotkeySource) {
            [void][WindowsShortcutControlNative]::UnregisterHotKey(
                $script:GlobalHotkeySource.Handle,
                $script:GlobalHotkeyId
            )
        }
    } catch {}

    $script:GlobalHotkeyRegistered = $false
}

function Register-GlobalHotkey {
    try {
        Initialize-HotkeyInterop

        if ($null -eq $script:GlobalHotkeySource) {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
            $handle = $helper.Handle

            if ($handle -eq [IntPtr]::Zero) {
                throw 'Window handle belum tersedia.'
            }

            $script:GlobalHotkeySource = [System.Windows.Interop.HwndSource]::FromHwnd($handle)

            $script:GlobalHotkeyHook = [System.Windows.Interop.HwndSourceHook]{
                param(
                    [IntPtr]$hwnd,
                    [int]$msg,
                    [IntPtr]$wParam,
                    [IntPtr]$lParam,
                    [ref]$handled
                )

                if ($msg -eq 0x0312 -and $wParam.ToInt32() -eq $script:GlobalHotkeyId) {
                    $handled.Value = $true

                    Invoke-OnUI {
                        Show-MainWindow
                        Show-CommandPalette
                    }
                }

                return [IntPtr]::Zero
            }

            $script:GlobalHotkeySource.AddHook($script:GlobalHotkeyHook)
        }

        Unregister-GlobalHotkey

        # MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, VK_SPACE = 0x20
        $registered = [WindowsShortcutControlNative]::RegisterHotKey(
            $script:GlobalHotkeySource.Handle,
            $script:GlobalHotkeyId,
            0x0001 -bor 0x0002,
            0x20
        )

        $script:GlobalHotkeyRegistered = [bool]$registered
        return [bool]$registered
    }
    catch {
        $script:GlobalHotkeyRegistered = $false
        return $false
    }
}

function Dispose-GlobalHotkeyInterop {
    try { Unregister-GlobalHotkey } catch {}

    try {
        if ($null -ne $script:GlobalHotkeySource -and $null -ne $script:GlobalHotkeyHook) {
            $script:GlobalHotkeySource.RemoveHook($script:GlobalHotkeyHook)
        }
    } catch {}

    $script:GlobalHotkeyHook = $null
    $script:GlobalHotkeySource = $null
}

function Apply-GlobalHotkeySetting {
    if ($null -eq $script:AppSettings) { return }

    if ([bool]$script:AppSettings.GlobalHotkey) {
        $ok = Register-GlobalHotkey

        if ($null -ne $script:TxtHotkeyStatus) {
            if ($ok) {
                $script:TxtHotkeyStatus.Text = (L 'Status: aktif' 'Status: active')
                $script:TxtHotkeyStatus.Foreground = '#15803D'
            } else {
                $script:TxtHotkeyStatus.Text = (L 'Status: gagal didaftarkan / sedang digunakan aplikasi lain' 'Status: registration failed / already used by another application')
                $script:TxtHotkeyStatus.Foreground = '#B42318'
            }
        }
    }
    else {
        Unregister-GlobalHotkey

        if ($null -ne $script:TxtHotkeyStatus) {
            $script:TxtHotkeyStatus.Text = (L 'Status: nonaktif' 'Status: disabled')
            $script:TxtHotkeyStatus.Foreground = '#667085'
        }
    }
}

function Apply-SettingsToUI {
    if ($null -eq $script:AppSettings) {
        Load-AppSettings
    }

    try {
        $script:UpdatingSettings = $true

        $script:ChkRunAtStartup.IsChecked = [bool]$script:AppSettings.RunAtStartup
        $script:ChkStartInTray.IsChecked = [bool]$script:AppSettings.StartInTray
        $script:ChkGlobalHotkey.IsChecked = [bool]$script:AppSettings.GlobalHotkey

        $targetLanguage = [string]$script:AppSettings.Language
        if ($targetLanguage -notin @('id','en')) { $targetLanguage = 'id' }
        for ($li=0; $li -lt $script:CmbLanguage.Items.Count; $li++) {
            $langItem = $script:CmbLanguage.Items[$li]
            if ([string]$langItem.Tag -eq $targetLanguage) {
                $script:CmbLanguage.SelectedIndex = $li
                break
            }
        }

        $targetTag = [string]$script:AppSettings.CloseBehavior
        $selected = 0

        for ($i=0; $i -lt $script:CmbCloseBehavior.Items.Count; $i++) {
            $item = $script:CmbCloseBehavior.Items[$i]
            if ([string]$item.Tag -eq $targetTag) {
                $selected = $i
                break
            }
        }

        $script:CmbCloseBehavior.SelectedIndex = $selected

        if ([bool]$script:AppSettings.GlobalHotkey) {
            if ($script:GlobalHotkeyRegistered) {
                $script:TxtHotkeyStatus.Text = (L 'Status: aktif' 'Status: active')
                $script:TxtHotkeyStatus.Foreground = '#15803D'
            } else {
                $script:TxtHotkeyStatus.Text = (L 'Status: menunggu / belum terdaftar' 'Status: waiting / not registered')
                $script:TxtHotkeyStatus.Foreground = '#667085'
            }
        } else {
            $script:TxtHotkeyStatus.Text = (L 'Status: nonaktif' 'Status: disabled')
            $script:TxtHotkeyStatus.Foreground = '#667085'
        }
    }
    finally {
        $script:UpdatingSettings = $false
    }
}

function Save-SettingsFromUI {
    try {
        $closeBehavior = 'Exit'

        if ($null -ne $script:CmbCloseBehavior.SelectedItem) {
            $tag = [string]$script:CmbCloseBehavior.SelectedItem.Tag
            if ($tag -in @('Exit','Tray')) {
                $closeBehavior = $tag
            }
        }

        $language = 'id'
        try {
            if ($null -ne $script:CmbLanguage.SelectedItem) {
                $candidateLanguage = [string]$script:CmbLanguage.SelectedItem.Tag
                if ($candidateLanguage -in @('id','en')) {
                    $language = $candidateLanguage
                }
            }
        } catch {}

        $newSettings = [pscustomobject][ordered]@{
            RunAtStartup        = [bool]$script:ChkRunAtStartup.IsChecked
            StartInTray         = [bool]$script:ChkStartInTray.IsChecked
            CloseBehavior       = $closeBehavior
            GlobalHotkey        = [bool]$script:ChkGlobalHotkey.IsChecked
            OnboardingCompleted = [bool]$script:AppSettings.OnboardingCompleted
            Language            = $language
        }

        $oldStartup = $false
        try { $oldStartup = [bool]$script:AppSettings.RunAtStartup } catch {}

        $script:AppSettings = Normalize-AppSettings $newSettings
        Save-AppSettings

        if ($oldStartup -ne [bool]$script:AppSettings.RunAtStartup -or
            [bool]$script:AppSettings.RunAtStartup) {

            $startupOk = Set-StartupRegistration ([bool]$script:AppSettings.RunAtStartup)
            if (-not $startupOk) {
                $script:AppSettings.RunAtStartup = $oldStartup
                Save-AppSettings
                Apply-SettingsToUI
                return
            }
        }

        Initialize-SystemTray
        Apply-GlobalHotkeySetting
        Apply-SettingsToUI
        Apply-AppLanguage

        Set-Status (L 'Settings berhasil disimpan.' 'Settings saved successfully.')
        Show-Info (L 'Settings berhasil disimpan dan langsung diterapkan.' 'Settings were saved and applied immediately.') (L 'Settings' 'Settings')
    }
    catch {
        Show-Error $_.Exception.Message 'Settings'
    }
}

function Show-CommandPalette {
    try {
        Initialize-ToolCatalog

        [xml]$paletteXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Command Palette"
        Width="620" Height="440"
        MinWidth="560" MinHeight="390"
        WindowStartupLocation="CenterOwner"
        Background="#F8FAFC"
        Foreground="#172033"
        FontFamily="Segoe UI"
        FontSize="13"
        ResizeMode="NoResize"
        WindowStyle="None"
        ShowInTaskbar="False">
    <Window.Resources>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#172033"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="FontSize" Value="15"/>
            <Setter Property="CaretBrush" Value="#172033"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="Margin" Value="0,1"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        </Style>
    </Window.Resources>

    <Border Background="#FFFFFF" BorderBrush="#D0D5DD" BorderThickness="1" CornerRadius="14">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="62"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="38"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" BorderBrush="#EAECF0" BorderThickness="0,0,0,1">
                <Grid Margin="18,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="28"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Path Data="M 11,11 m -5,0 a 5,5 0 1,0 10,0 a 5,5 0 1,0 -10,0 M 14.5,14.5 L 19,19"
                          Stroke="#98A2B3" StrokeThickness="1.4"
                          Width="18" Height="18" Stretch="Uniform"
                          VerticalAlignment="Center"/>
                    <TextBox x:Name="PaletteSearch" Grid.Column="1"
                             VerticalContentAlignment="Center"
                             ToolTip="Cari command, shortcut, atau Windows Tool"/>
                    <Border Grid.Column="2" Background="#F2F4F7" CornerRadius="5"
                            Padding="6,3" VerticalAlignment="Center">
                        <TextBlock Text="ESC" Foreground="#667085" FontSize="9"/>
                    </Border>
                </Grid>
            </Border>

            <ListBox x:Name="PaletteList" Grid.Row="1" Margin="8">
                <ListBox.ItemTemplate>
                    <DataTemplate>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="{Binding Label}" Foreground="#172033"
                                           FontWeight="SemiBold" FontSize="12"/>
                                <TextBlock Text="{Binding Detail}" Foreground="#98A2B3"
                                           FontSize="10" Margin="0,2,0,0"/>
                            </StackPanel>
                            <Border Grid.Column="1" Background="#F8FAFC"
                                    BorderBrush="#EAECF0" BorderThickness="1"
                                    CornerRadius="5" Padding="6,2"
                                    VerticalAlignment="Center">
                                <TextBlock Text="{Binding Kind}" Foreground="#667085" FontSize="9"/>
                            </Border>
                        </Grid>
                    </DataTemplate>
                </ListBox.ItemTemplate>
            </ListBox>

            <Border Grid.Row="2" BorderBrush="#EAECF0" BorderThickness="0,1,0,0">
                <TextBlock Text="↑↓ pilih   Enter jalankan   Esc tutup"
                           Foreground="#98A2B3" FontSize="9.5"
                           VerticalAlignment="Center" Margin="18,0"/>
            </Border>
        </Grid>
    </Border>
</Window>
'@

        $reader = New-Object System.Xml.XmlNodeReader $paletteXaml
        $paletteWindow = [Windows.Markup.XamlReader]::Load($reader)
        $paletteWindow.Owner = $window

        $PaletteSearch = $paletteWindow.FindName('PaletteSearch')
        $PaletteList = $paletteWindow.FindName('PaletteList')

        $paletteState = [pscustomobject]@{
            Dialog = $paletteWindow
            Search = $PaletteSearch
            List   = $PaletteList
        }
        $paletteWindow.Tag = $paletteState
        $PaletteSearch.Tag = $paletteState
        $PaletteList.Tag = $paletteState

        Apply-LanguageToElement $paletteWindow

        $refreshPalette = {
            param($state)
            if ($null -eq $state) { return }
            $q = ([string]$state.Search.Text).Trim().ToLowerInvariant()
            $results = New-Object System.Collections.Generic.List[object]

            # Built-in navigation/actions.
            $commands = @(
                @{ Label=(L 'Tambah Shortcut' 'Add Shortcut'); Detail=(L 'Buat shortcut baru' 'Create a new shortcut'); Code='New'; Kind='COMMAND' }
                @{ Label='Dashboard'; Detail=(L 'Buka halaman Dashboard' 'Open Dashboard page'); Code='Dashboard'; Kind='PAGE' }
                @{ Label=(L 'Shortcut' 'Shortcuts'); Detail=(L 'Buka daftar shortcut' 'Open shortcut list'); Code='Shortcuts'; Kind='PAGE' }
                @{ Label=(L 'Alat Windows' 'Windows Tools'); Detail=(L 'Buka Windows Tools' 'Open Windows Tools'); Code='Tools'; Kind='PAGE' }
                @{ Label=(L 'Info Sistem' 'System Info'); Detail=(L 'Buka informasi sistem dan Live Monitor' 'Open system information and Live Monitor'); Code='System'; Kind='PAGE' }
                @{ Label=(L 'Pengaturan' 'Settings'); Detail=(L 'Startup, tray, backup, dan diagnostics' 'Startup, tray, backup, and diagnostics'); Code='Settings'; Kind='PAGE' }
                @{ Label=(L 'Tentang' 'About'); Detail=(L 'Informasi aplikasi, pengembang, pemilik, kontak, dan tanggal pembuatan' 'Application, developer, owner, contact, and creation information'); Code='About'; Kind='COMMAND' }
                @{ Label='Keyboard Shortcuts'; Detail=(L 'Lihat semua shortcut keyboard yang tersedia' 'View all available keyboard shortcuts'); Code='KeyboardShortcuts'; Kind='COMMAND' }
                @{ Label=(L 'Panduan Penggunaan' 'User Guide'); Detail=(L 'Buka panduan menu utama dan cara menggunakan aplikasi' 'Open the guide to main menus and application usage'); Code='GettingStarted'; Kind='COMMAND' }
                @{ Label=(L 'Backup Konfigurasi Lengkap' 'Backup Full Config'); Detail=(L 'Backup shortcut + seluruh settings' 'Back up shortcuts + all settings'); Code='BackupConfig'; Kind='COMMAND' }
                @{ Label=(L 'Pulihkan Konfigurasi Lengkap' 'Restore Full Config'); Detail=(L 'Restore shortcut + seluruh settings' 'Restore shortcuts + all settings'); Code='RestoreConfig'; Kind='COMMAND' }
                @{ Label='Self Diagnostics'; Detail=(L 'Periksa kesehatan komponen aplikasi' 'Check application component health'); Code='Diagnostics'; Kind='COMMAND' }
            )

            foreach ($cmd in $commands) {
                $hay = ($cmd.Label + ' ' + $cmd.Detail).ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($q) -or $hay.Contains($q)) {
                    [void]$results.Add([pscustomobject]@{
                        Label=$cmd.Label; Detail=$cmd.Detail; Kind=$cmd.Kind
                        RefType='Command'; Ref=$cmd.Code
                    })
                }
            }

            $shortcutCandidates = @($script:ShortcutStore)
            if ([string]::IsNullOrWhiteSpace($q)) {
                $shortcutCandidates = @(
                    $shortcutCandidates |
                    Sort-Object -Property @{
                        Expression = { if ([bool]$_.Pinned) { 3 } elseif ([bool]$_.Favorite) { 2 } else { 1 } }
                        Descending = $true
                    }, @{
                        Expression = { [int]$_.OpenCount }
                        Descending = $true
                    } |
                    Select-Object -First 12
                )
            }

            foreach ($item in $shortcutCandidates) {
                $hay = ("{0} {1} {2} {3}" -f $item.Name,$item.Type,$item.Category,$item.Target).ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($q) -or $hay.Contains($q)) {
                    [void]$results.Add([pscustomobject]@{
                        Label=[string]$item.Name
                        Detail=("{0} · {1}" -f $item.Category,$item.Target)
                        Kind='SHORTCUT'
                        RefType='Shortcut'
                        Ref=[string]$item.Id
                    })
                }
            }

            for ($i=0; $i -lt @($script:ToolCatalog).Count; $i++) {
                $tool = $script:ToolCatalog[$i]
                $hay = ("{0} {1} {2}" -f $tool.T,$tool.S,$tool.C).ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($q) -and -not $hay.Contains($q)) {
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($q) -and $i -ge 8) {
                    continue
                }

                [void]$results.Add([pscustomobject]@{
                    Label=[string]$tool.T
                    Detail=("{0} · {1}" -f $tool.C,$tool.S)
                    Kind='TOOL'
                    RefType='Tool'
                    Ref=[string]$i
                })
            }

            $state.List.ItemsSource = @($results.ToArray())
            if ($state.List.Items.Count -gt 0) {
                $state.List.SelectedIndex = 0
            }
        }

        $invokePalette = {
            param($state)
            if ($null -eq $state) { return }
            $selected = $state.List.SelectedItem
            if ($null -eq $selected) { return }

            $refType = [string]$selected.RefType
            $ref = [string]$selected.Ref

            $state.Dialog.Close()

            switch ($refType) {
                'Shortcut' {
                    $item = Get-ShortcutById $ref
                    if ($null -ne $item) { Open-Target $item }
                }
                'Tool' {
                    $idx = 0
                    if ([int]::TryParse($ref, [ref]$idx)) {
                        if ($idx -ge 0 -and $idx -lt @($script:ToolCatalog).Count) {
                            $toolAction = $script:ToolCatalog[$idx].A
                            if ($null -ne $toolAction) {
                                & $toolAction
                            }
                        }
                    }
                }
                'Command' {
                    switch ($ref) {
                        'New'       { Add-ShortcutDialog }
                        'Dashboard' { Show-Page 'Dashboard' }
                        'Shortcuts' { Show-Page 'Shortcuts' }
                        'Tools'     { Show-Page 'Tools' }
                        'System'        { Show-Page 'System' }
                        'Settings'      { Show-Page 'Settings' }
                        'About'             { Show-AboutDialog }
                        'KeyboardShortcuts' { Show-KeyboardShortcutsDialog }
                        'GettingStarted'    { Show-GettingStartedGuide }
                        'BackupConfig'      { Export-AppConfiguration }
                        'RestoreConfig' { Import-AppConfiguration }
                        'Diagnostics'   { Show-SelfDiagnostics }
                    }
                }
            }
        }

        $PaletteSearch.Add_TextChanged({
            param($sender,$e)
            try {
                $s = $sender.Tag
                & $refreshPalette $s
            } catch {}
        })

        $PaletteSearch.Add_KeyDown({
            param($sender,$e)
            try {
                $s = $sender.Tag
                if ($null -eq $s) { return }

                if ($e.Key -eq 'Down') {
                    if ($s.List.Items.Count -gt 0) {
                        $s.List.Focus() | Out-Null
                        if ($s.List.SelectedIndex -lt 0) { $s.List.SelectedIndex = 0 }
                    }
                    $e.Handled = $true
                }
                elseif ($e.Key -eq 'Enter') {
                    & $invokePalette $s
                    $e.Handled = $true
                }
                elseif ($e.Key -eq 'Escape') {
                    $s.Dialog.Close()
                    $e.Handled = $true
                }
            } catch {}
        })

        $PaletteList.Add_KeyDown({
            param($sender,$e)
            try {
                $s = $sender.Tag
                if ($null -eq $s) { return }

                if ($e.Key -eq 'Enter') {
                    & $invokePalette $s
                    $e.Handled = $true
                }
                elseif ($e.Key -eq 'Escape') {
                    $s.Dialog.Close()
                    $e.Handled = $true
                }
                elseif ($e.Key -eq 'Up' -and $s.List.SelectedIndex -le 0) {
                    $s.Search.Focus() | Out-Null
                    $s.Search.SelectAll()
                    $e.Handled = $true
                }
            } catch {}
        })

        $PaletteList.Add_MouseDoubleClick({
            param($sender,$e)
            try {
                $s = $sender.Tag
                & $invokePalette $s
            } catch {}
        })

        & $refreshPalette $paletteState

        $paletteWindow.Add_ContentRendered({
            param($sender,$e)
            try {
                $s = $sender.Tag
                if ($null -ne $s) { $s.Search.Focus() | Out-Null }
            } catch {}
        })

        [void]$paletteWindow.ShowDialog()
    }
    catch {
        Show-Error $_.Exception.Message (L 'Command Palette' 'Command Palette')
    }
}

function Set-OnboardingCompleted {
    try {
        if ($null -eq $script:AppSettings) {
            Load-AppSettings
        }

        $script:AppSettings.OnboardingCompleted = $true
        Save-AppSettings
    } catch {}
}

function Update-GettingStartedGuideStep {
    param([object]$State)

    try {
        if ($null -eq $State -or $null -eq $State.Dialog) { return }

        $items = @($State.Steps)
        if ($items.Count -eq 0) { return }

        $idx = 0
        try { $idx = [int]$State.Index } catch { $idx = 0 }

        if ($idx -lt 0) { $idx = 0 }
        if ($idx -ge $items.Count) { $idx = $items.Count - 1 }
        $State.Index = $idx

        $item = $items[$idx]
        $num = $idx + 1

        if ((Get-AppLanguage) -eq 'en') {
            $State.StepLabel.Text = "STEP $num OF $($items.Count)"
        } else {
            $State.StepLabel.Text = "LANGKAH $num DARI $($items.Count)"
        }
        $State.TitleControl.Text = Convert-UiText ([string]$item.Title)
        $State.SubtitleControl.Text = Convert-UiText ([string]$item.Subtitle)
        $State.DescriptionControl.Text = Convert-UiText ([string]$item.Description)
        $State.TipsControl.Text = Convert-UiText ([string]$item.Tips)
        $State.Progress.Maximum = $items.Count
        $State.Progress.Value = $num
        $State.BackButton.IsEnabled = ($idx -gt 0)

        if ($idx -eq ($items.Count - 1)) {
            $State.NextButton.Content = (L 'Selesai' 'Finish')
        } else {
            $State.NextButton.Content = (L 'Berikutnya' 'Next')
        }

        if ([string]::IsNullOrWhiteSpace([string]$item.Page)) {
            $State.ShowPageButton.Visibility = 'Collapsed'
        } else {
            $State.ShowPageButton.Visibility = 'Visible'
            $State.ShowPageButton.Content = Convert-UiText ([string]$item.PageButton)
        }
    } catch {
        Show-Error $_.Exception.Message 'Panduan Penggunaan'
    }
}

function Complete-GettingStartedGuide {
    param([object]$State)

    try {
        if ($null -eq $State) { return }

        if ([bool]$State.IsFirstRun) {
            Set-OnboardingCompleted
        }

        $State.CompletedByButton = $true

        if ($null -ne $State.Dialog) {
            $State.Dialog.Close()
        }
    } catch {
        # Closing the guide must never produce another blocking error.
        try {
            if ($null -ne $State.Dialog) {
                $State.Dialog.Hide()
            }
        } catch {}
    }
}

function Show-GettingStartedGuide {
    param([switch]$FirstRun)

    try {
        $guideSteps = @(
            [pscustomobject]@{
                Title='Selamat Datang'
                Subtitle='Kenali Windows Shortcut Control dalam beberapa langkah singkat.'
                Description='Windows Shortcut Control adalah launcher dan pusat kontrol Windows untuk membuka aplikasi, file, folder, URL, perintah PowerShell, serta berbagai alat bawaan Windows dari satu tempat.'
                Tips='Gunakan Berikutnya dan Sebelumnya untuk berpindah langkah. Panduan dapat dilewati kapan saja dan bisa dibuka kembali melalui About, Settings, Command Palette, atau tombol F1.'
                Page='Dashboard'
                PageButton='Buka Dashboard'
            },
            [pscustomobject]@{
                Title='Dashboard'
                Subtitle='Halaman utama untuk akses cepat.'
                Description='Dashboard menampilkan shortcut yang Anda pin, daftar Favorit, dan shortcut yang terakhir digunakan. Gunakan halaman ini untuk menyimpan item penting agar mudah dijangkau.'
                Tips='Klik kanan shortcut lalu pilih Pin ke Dashboard atau Tambah ke Favorit. Bagian Terbaru diperbarui otomatis setelah shortcut berhasil dibuka.'
                Page='Dashboard'
                PageButton='Buka Dashboard'
            },
            [pscustomobject]@{
                Title='Menu Shortcuts'
                Subtitle='Tempat membuat dan mengelola semua shortcut pribadi.'
                Description='Halaman Shortcuts dapat menyimpan Folder, File, Aplikasi, URL, dan perintah PowerShell. Gunakan Tambah Shortcut untuk membuatnya secara manual, atau tarik file/folder langsung dari Windows Explorer ke jendela aplikasi.'
                Tips='Gunakan pencarian dan filter untuk menemukan shortcut. Klik kanan shortcut untuk Edit, Duplicate, Run as Administrator, Pin, Favorit, Open Location, dan tindakan lainnya.'
                Page='Shortcuts'
                PageButton='Buka Shortcuts'
            },
            [pscustomobject]@{
                Title='Windows Tools'
                Subtitle='Akses cepat ke alat administrasi Windows.'
                Description='Windows Tools menyediakan Task Manager, Services, Task Scheduler, Device Manager, Disk Management, Registry Editor, PowerShell, Command Prompt, Network Connections, fitur recovery, backup, dan berbagai alat lainnya.'
                Tips='Gunakan kotak pencarian. Contoh: task untuk Task Manager, device untuk Device Manager, registry untuk Registry Editor, atau backup untuk pencadangan.'
                Page='Tools'
                PageButton='Buka Windows Tools'
            },
            [pscustomobject]@{
                Title='System Info & Live Monitor'
                Subtitle='Lihat informasi komputer dan penggunaan resource secara langsung.'
                Description='System Info menampilkan informasi Windows, prosesor, RAM, uptime, dan penyimpanan. Live Monitor memperbarui penggunaan CPU, RAM, kecepatan download, dan upload secara berkala.'
                Tips='Live Monitor hanya aktif saat halaman System Info dibuka. Ketika pindah halaman, monitoring otomatis berhenti agar aplikasi tetap ringan.'
                Page='System'
                PageButton='Buka System Info'
            },
            [pscustomobject]@{
                Title='Pencarian & Command Palette'
                Subtitle='Temukan dan jalankan fitur tanpa membuka menu satu per satu.'
                Description='Global Search dapat mencari shortcut dan Windows Tools. Command Palette menyediakan akses cepat ke halaman, shortcut, tools, backup, diagnostics, About, dan berbagai perintah aplikasi.'
                Tips='Ctrl + F membuka Global Search. Ctrl + K membuka Command Palette. Ctrl + Alt + Space membuka aplikasi sekaligus Command Palette dari aplikasi lain jika Global Hotkey aktif.'
                Page=''
                PageButton=''
            },
            [pscustomobject]@{
                Title='Settings, Startup & System Tray'
                Subtitle='Atur bagaimana aplikasi berjalan di Windows.'
                Description='Di Settings Anda dapat mengaktifkan aplikasi saat login Windows, menjalankannya langsung ke System Tray, menentukan fungsi tombol Close, mengatur Global Hotkey, membuka panduan, melakukan backup/restore, dan menjalankan Self Diagnostics.'
                Tips='Walaupun Start in Tray aktif, double-click file aplikasi secara manual tetap membuka jendela utama. Gunakan Ctrl + Shift + T untuk mengirim aplikasi ke System Tray.'
                Page='Settings'
                PageButton='Buka Settings'
            },
            [pscustomobject]@{
                Title='Backup, Recovery & Bantuan'
                Subtitle='Lindungi konfigurasi dan ketahui cara mendapatkan bantuan.'
                Description='Backup Config menyimpan shortcut dan Settings dalam satu file. Last Known Good dan backup Registry membantu memulihkan data jika terjadi masalah. Self Diagnostics memeriksa storage, startup, tray, hotkey, runspace, dan komponen utama lainnya.'
                Tips='Tekan F1 kapan saja untuk membuka panduan ini kembali. Menu About berisi informasi aplikasi dan pengembang. Keyboard Shortcuts berisi daftar lengkap tombol pintas.'
                Page=''
                PageButton=''
            }
        )

        [xml]$guideXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Panduan Penggunaan"
        Width="650" Height="500"
        MinWidth="600" MinHeight="460"
        WindowStartupLocation="CenterOwner"
        Background="#F6F8FC"
        Foreground="#172033"
        FontFamily="Segoe UI"
        FontSize="12"
        ResizeMode="NoResize"
        ShowInTaskbar="False">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#EAECF0"
                BorderThickness="0,0,0,1" Padding="22,18">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Border Width="44" Height="44" Background="#2563EB" CornerRadius="11">
                    <Viewbox Width="27" Height="27"
                             HorizontalAlignment="Center" VerticalAlignment="Center">
                        <Canvas Width="24" Height="24">
                            <Path Data="M 4.5,5.5 L 17.5,5.5 L 17.5,15.5 L 4.5,15.5 Z
                                        M 11,5.5 L 11,15.5
                                        M 4.5,10.5 L 17.5,10.5
                                        M 13.5,19 L 20,12.5
                                        M 16.5,12.5 L 20,12.5 L 20,16"
                                  Stroke="#FFFFFF" StrokeThickness="1.65"
                                  StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                  StrokeLineJoin="Round" Fill="Transparent"/>
                        </Canvas>
                    </Viewbox>
                </Border>

                <StackPanel Grid.Column="1" Margin="13,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="Panduan Penggunaan" Foreground="#172033"
                               FontSize="17" FontWeight="SemiBold"/>
                    <TextBlock Text="Panduan singkat Windows Shortcut Control"
                               Foreground="#667085" FontSize="10" Margin="0,2,0,0"/>
                </StackPanel>

                <Border Grid.Column="2" Background="#EFF6FF" CornerRadius="6"
                        Padding="8,4" VerticalAlignment="Center">
                    <TextBlock x:Name="GuideStepLabel" Text="LANGKAH 1 DARI 8"
                               Foreground="#1D4ED8" FontSize="9" FontWeight="Bold"/>
                </Border>
            </Grid>
        </Border>

        <Grid Grid.Row="1" Margin="26,22">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock x:Name="GuideTitle" Text="Selamat Datang"
                       Foreground="#172033" FontSize="25" FontWeight="Bold"
                       TextWrapping="Wrap"/>

            <TextBlock x:Name="GuideSubtitle" Grid.Row="1"
                       Foreground="#667085" FontSize="11"
                       Margin="0,5,0,0" TextWrapping="Wrap"/>

            <TextBlock x:Name="GuideDescription" Grid.Row="2"
                       Foreground="#475467" FontSize="12" LineHeight="20"
                       Margin="0,18,0,16" TextWrapping="Wrap"
                       VerticalAlignment="Top"/>

            <Border Grid.Row="3" Background="#F8FAFC" BorderBrush="#EAECF0"
                    BorderThickness="1" CornerRadius="10" Padding="13">
                <StackPanel>
                    <TextBlock Text="TIPS" Foreground="#98A2B3"
                               FontSize="9" FontWeight="Bold"/>
                    <TextBlock x:Name="GuideTips" Foreground="#475467"
                               FontSize="10.5" LineHeight="17"
                               Margin="0,5,0,0" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <ProgressBar x:Name="GuideProgress" Grid.Row="4"
                         Height="4" Minimum="0" Maximum="8" Value="1"
                         Margin="0,18,0,0" BorderThickness="0"/>
        </Grid>

        <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#EAECF0"
                BorderThickness="0,1,0,0" Padding="18,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Button x:Name="GuideBack" Content="Sebelumnya"
                        Padding="14,7" IsEnabled="False"/>

                <Button x:Name="GuideShowPage" Grid.Column="1"
                        Content="Buka Dashboard" Padding="14,7"
                        HorizontalAlignment="Center"/>

                <StackPanel Grid.Column="2" Orientation="Horizontal">
                    <Button x:Name="GuideSkip" Content="Lewati Panduan"
                            Padding="14,7" Margin="0,0,8,0"/>
                    <Button x:Name="GuideNext" Content="Berikutnya"
                            Padding="18,7"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

        $reader = New-Object System.Xml.XmlNodeReader $guideXaml
        $guideWindow = [Windows.Markup.XamlReader]::Load($reader)
        $guideWindow.Owner = $window

        if ($null -ne $script:WindowLogoSource) {
            try { $guideWindow.Icon = $script:WindowLogoSource } catch {}
        }

        $state = [pscustomobject]@{
            Index              = 0
            CompletedByButton  = $false
            IsFirstRun         = [bool]$FirstRun
            Steps              = $guideSteps
            Dialog             = $guideWindow
            StepLabel          = $guideWindow.FindName('GuideStepLabel')
            TitleControl       = $guideWindow.FindName('GuideTitle')
            SubtitleControl    = $guideWindow.FindName('GuideSubtitle')
            DescriptionControl = $guideWindow.FindName('GuideDescription')
            TipsControl        = $guideWindow.FindName('GuideTips')
            Progress           = $guideWindow.FindName('GuideProgress')
            BackButton         = $guideWindow.FindName('GuideBack')
            ShowPageButton     = $guideWindow.FindName('GuideShowPage')
            SkipButton         = $guideWindow.FindName('GuideSkip')
            NextButton         = $guideWindow.FindName('GuideNext')
        }

        $guideWindow.Tag = $state
        $state.BackButton.Tag = $state
        $state.ShowPageButton.Tag = $state
        $state.SkipButton.Tag = $state
        $state.NextButton.Tag = $state

        Apply-LanguageToElement $guideWindow

        if (-not [bool]$state.IsFirstRun) {
            $state.SkipButton.Content = (L 'Tutup Panduan' 'Close Guide')
        } else {
            $state.SkipButton.Content = (L 'Lewati Panduan' 'Skip Guide')
        }

        $state.BackButton.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s) { return }

                if ([int]$s.Index -gt 0) {
                    $s.Index = [int]$s.Index - 1
                    Update-GettingStartedGuideStep $s
                }
            } catch {
                Show-Error $_.Exception.Message 'Panduan Penggunaan'
            }
        })

        $state.NextButton.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s) { return }

                $countLocal = @($s.Steps).Count
                if ([int]$s.Index -lt ($countLocal - 1)) {
                    $s.Index = [int]$s.Index + 1
                    Update-GettingStartedGuideStep $s
                } else {
                    Complete-GettingStartedGuide $s
                }
            } catch {
                Show-Error $_.Exception.Message 'Panduan Penggunaan'
            }
        })

        $state.SkipButton.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s) { return }
                Complete-GettingStartedGuide $s
            } catch {}
        })

        $state.ShowPageButton.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s) { return }

                $itemsLocal = @($s.Steps)
                $idxLocal = [int]$s.Index
                if ($idxLocal -lt 0 -or $idxLocal -ge $itemsLocal.Count) { return }

                $itemLocal = $itemsLocal[$idxLocal]
                if (-not [string]::IsNullOrWhiteSpace([string]$itemLocal.Page)) {
                    Show-Page ([string]$itemLocal.Page)
                }
            } catch {
                Show-Error $_.Exception.Message 'Panduan Penggunaan'
            }
        })

        $guideWindow.Add_Closing({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s) { return }

                if ([bool]$s.IsFirstRun -and -not [bool]$s.CompletedByButton) {
                    Set-OnboardingCompleted
                }
            } catch {}
        })

        $guideWindow.Add_Closed({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                $sender.Tag = $null

                if ($null -ne $s) {
                    try { $s.BackButton.Tag = $null } catch {}
                    try { $s.ShowPageButton.Tag = $null } catch {}
                    try { $s.SkipButton.Tag = $null } catch {}
                    try { $s.NextButton.Tag = $null } catch {}
                }
            } catch {}
        })

        Update-GettingStartedGuideStep $state
        [void]$guideWindow.ShowDialog()
    } catch {
        Show-Error $_.Exception.Message 'Panduan Penggunaan'
    }
}

function Show-FirstRunGuideIfNeeded {
    try {
        if ($script:IsStartupLaunch) { return }

        if ($null -eq $script:AppSettings) {
            Load-AppSettings
        }

        if ([bool]$script:AppSettings.OnboardingCompleted) {
            return
        }

        Show-MainWindow
        Show-GettingStartedGuide -FirstRun
    }
    catch {}
}

function Show-KeyboardShortcutsDialog {
    param([System.Windows.Window]$OwnerWindow = $null)

    try {
        [xml]$shortcutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Keyboard Shortcuts"
        Width="760" Height="610"
        MinWidth="680" MinHeight="520"
        WindowStartupLocation="CenterOwner"
        Background="#F6F8FC"
        Foreground="#172033"
        FontFamily="Segoe UI"
        FontSize="12"
        ResizeMode="CanResize"
        ShowInTaskbar="False">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#EAECF0"
                BorderThickness="0,0,0,1" Padding="22,18">
            <StackPanel>
                <TextBlock Text="Keyboard Shortcuts" FontSize="22"
                           FontWeight="Bold" Foreground="#172033"/>
                <TextBlock Text="Quick keyboard access for navigation, search, backup, diagnostics, and application controls."
                           Foreground="#667085" FontSize="10.5" Margin="0,4,0,0"/>
            </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="20,16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Border Background="#EFF6FF" BorderBrush="#DBEAFE"
                    BorderThickness="1" CornerRadius="10" Padding="12" Margin="0,0,0,12">
                <TextBlock TextWrapping="Wrap" Foreground="#475467" FontSize="10.5"
                           Text="Tip: Ctrl + Alt + Space is a global shortcut and can open Windows Shortcut Control from another application when Global Hotkey is enabled in Settings."/>
            </Border>

            <DataGrid x:Name="ShortcutGrid" Grid.Row="1"
                      AutoGenerateColumns="False" IsReadOnly="True"
                      CanUserAddRows="False" CanUserDeleteRows="False"
                      CanUserResizeRows="False" HeadersVisibility="Column"
                      GridLinesVisibility="Horizontal" Background="#FFFFFF"
                      BorderBrush="#E4E7EC" BorderThickness="1" RowHeaderWidth="0"
                      SelectionMode="Single" SelectionUnit="FullRow">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="125"/>
                    <DataGridTextColumn Header="Shortcut" Binding="{Binding Shortcut}" Width="155"/>
                    <DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="*"/>
                </DataGrid.Columns>
            </DataGrid>
        </Grid>

        <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#EAECF0"
                BorderThickness="0,1,0,0" Padding="18,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <TextBlock Text="Windows Shortcut Control · Keyboard Reference"
                           Foreground="#98A2B3" FontSize="10" VerticalAlignment="Center"/>

                <Button x:Name="CloseShortcutHelp" Grid.Column="1"
                        Content="Close" Padding="16,7"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

        $reader = New-Object System.Xml.XmlNodeReader $shortcutXaml
        $shortcutWindow = [Windows.Markup.XamlReader]::Load($reader)

        if ($null -ne $OwnerWindow) {
            $shortcutWindow.Owner = $OwnerWindow
        } else {
            $shortcutWindow.Owner = $window
        }

        if ($null -ne $script:WindowLogoSource) {
            try { $shortcutWindow.Icon = $script:WindowLogoSource } catch {}
        }

        $grid = $shortcutWindow.FindName('ShortcutGrid')
        $closeButton = $shortcutWindow.FindName('CloseShortcutHelp')

        $rows = @(
            [pscustomobject]@{ Category=(L 'Global' 'Global'); Shortcut='Ctrl + Alt + Space'; Action=(L 'Buka aplikasi dan Command Palette dari mana saja di Windows.' 'Open the application and Command Palette from anywhere in Windows.') }

            [pscustomobject]@{ Category=(L 'Umum' 'General'); Shortcut='Ctrl + K'; Action=(L 'Buka Command Palette.' 'Open Command Palette.') }
            [pscustomobject]@{ Category=(L 'Umum' 'General'); Shortcut='Ctrl + N'; Action=(L 'Buat shortcut baru.' 'Create a new shortcut.') }
            [pscustomobject]@{ Category=(L 'Umum' 'General'); Shortcut='Ctrl + F'; Action=(L 'Fokus ke Global Search.' 'Focus Global Search.') }
            [pscustomobject]@{ Category=(L 'Umum' 'General'); Shortcut='Ctrl + Shift + F'; Action=(L 'Buka halaman Shortcuts dan fokus ke pencarian shortcut.' 'Open Shortcuts page and focus Shortcut Search.') }
            [pscustomobject]@{ Category=(L 'Umum' 'General'); Shortcut='F5'; Action=(L 'Perbarui data dan tampilan aplikasi.' 'Refresh the current application data and views.') }
            [pscustomobject]@{ Category=(L 'Bantuan' 'Help'); Shortcut='F1'; Action=(L 'Buka Panduan Penggunaan aplikasi.' 'Open the application User Guide.') }

            [pscustomobject]@{ Category=(L 'Navigasi' 'Navigation'); Shortcut='Alt + 1'; Action=(L 'Buka Dashboard.' 'Open Dashboard.') }
            [pscustomobject]@{ Category=(L 'Navigasi' 'Navigation'); Shortcut='Alt + 2'; Action=(L 'Buka Shortcuts.' 'Open Shortcuts.') }
            [pscustomobject]@{ Category=(L 'Navigasi' 'Navigation'); Shortcut='Alt + 3'; Action=(L 'Buka Windows Tools.' 'Open Windows Tools.') }
            [pscustomobject]@{ Category=(L 'Navigasi' 'Navigation'); Shortcut='Alt + 4'; Action=(L 'Buka System Info dan Live Monitor.' 'Open System Info and Live Monitor.') }
            [pscustomobject]@{ Category=(L 'Navigasi' 'Navigation'); Shortcut='Alt + 5'; Action=(L 'Buka Settings.' 'Open Settings.') }
            [pscustomobject]@{ Category=(L 'Navigasi' 'Navigation'); Shortcut='Ctrl + ,'; Action=(L 'Buka Settings.' 'Open Settings.') }
            [pscustomobject]@{ Category=(L 'Navigasi' 'Navigation'); Shortcut='Ctrl + Shift + A'; Action=(L 'Buka About.' 'Open About.') }

            [pscustomobject]@{ Category=(L 'Data' 'Data'); Shortcut='Ctrl + E'; Action=(L 'Ekspor data shortcut.' 'Export shortcut data.') }
            [pscustomobject]@{ Category=(L 'Data' 'Data'); Shortcut='Ctrl + I'; Action=(L 'Impor data shortcut.' 'Import shortcut data.') }
            [pscustomobject]@{ Category=(L 'Data' 'Data'); Shortcut='Ctrl + B'; Action=(L 'Buat backup konfigurasi lengkap.' 'Create a full configuration backup.') }
            [pscustomobject]@{ Category=(L 'Data' 'Data'); Shortcut='Ctrl + Shift + B'; Action=(L 'Pulihkan backup konfigurasi lengkap.' 'Restore a full configuration backup.') }

            [pscustomobject]@{ Category=(L 'Sistem' 'System'); Shortcut='Ctrl + Shift + D'; Action=(L 'Jalankan Self Diagnostics.' 'Run Self Diagnostics.') }
            [pscustomobject]@{ Category=(L 'Sistem' 'System'); Shortcut='Ctrl + Shift + T'; Action=(L 'Minimize Windows Shortcut Control ke System Tray.' 'Minimize Windows Shortcut Control to System Tray.') }

            [pscustomobject]@{ Category='Command Palette'; Shortcut='Up / Down'; Action=(L 'Pindah pilihan pada hasil Command Palette.' 'Move through Command Palette results.') }
            [pscustomobject]@{ Category='Command Palette'; Shortcut='Enter'; Action=(L 'Jalankan item Command Palette yang dipilih.' 'Run the selected Command Palette item.') }
            [pscustomobject]@{ Category='Command Palette'; Shortcut='Esc'; Action=(L 'Tutup Command Palette.' 'Close Command Palette.') }
        )

        $grid.ItemsSource = $rows

        try {
            $grid.Columns[0].Header = (L 'Kategori' 'Category')
            $grid.Columns[1].Header = 'Shortcut'
            $grid.Columns[2].Header = (L 'Aksi' 'Action')
        } catch {}

        $shortcutState = [pscustomobject]@{ Dialog = $shortcutWindow }
        $shortcutWindow.Tag = $shortcutState
        $closeButton.Tag = $shortcutState

        Apply-LanguageToElement $shortcutWindow

        $closeButton.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -ne $s -and $null -ne $s.Dialog) {
                    $s.Dialog.Close()
                }
            } catch {}
        })

        [void]$shortcutWindow.ShowDialog()
    }
    catch {
        Show-Error $_.Exception.Message (L 'Keyboard Shortcuts' 'Keyboard Shortcuts')
    }
}

function Show-AboutDialog {
    try {
        [xml]$aboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About Windows Shortcut Control"
        Width="700" Height="610"
        MinWidth="640" MinHeight="560"
        WindowStartupLocation="CenterOwner"
        Background="#F6F8FC"
        Foreground="#172033"
        FontFamily="Segoe UI"
        FontSize="12"
        ResizeMode="CanResize"
        ShowInTaskbar="False">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0"
                Background="#FFFFFF"
                BorderBrush="#EAECF0"
                BorderThickness="0,0,0,1"
                Padding="22,20">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border Width="56" Height="56"
                        Background="#2563EB"
                        CornerRadius="14"
                        VerticalAlignment="Top">
                    <Viewbox Width="34" Height="34"
                             HorizontalAlignment="Center"
                             VerticalAlignment="Center">
                        <Canvas Width="24" Height="24">
                            <Path Data="M 4.5,5.5 L 17.5,5.5 L 17.5,15.5 L 4.5,15.5 Z
                                        M 11,5.5 L 11,15.5
                                        M 4.5,10.5 L 17.5,10.5
                                        M 13.5,19 L 20,12.5
                                        M 16.5,12.5 L 20,12.5 L 20,16"
                                  Stroke="#FFFFFF"
                                  StrokeThickness="1.65"
                                  StrokeStartLineCap="Round"
                                  StrokeEndLineCap="Round"
                                  StrokeLineJoin="Round"
                                  Fill="Transparent"/>
                        </Canvas>
                    </Viewbox>
                </Border>

                <StackPanel Grid.Column="1" Margin="16,0,0,0">
                    <TextBlock Text="Windows Shortcut Control"
                               FontSize="22"
                               FontWeight="Bold"
                               Foreground="#172033"/>
                    <TextBlock Text="Productivity Launcher &amp; Windows Control Center"
                               FontSize="11"
                               Foreground="#667085"
                               Margin="0,4,0,0"/>
                    <TextBlock x:Name="AboutVersion"
                               FontSize="10"
                               Foreground="#98A2B3"
                               Margin="0,8,0,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <ScrollViewer Grid.Row="1"
                      VerticalScrollBarVisibility="Auto"
                      Margin="20,18">
            <StackPanel>
                <Border Background="#FFFFFF"
                        BorderBrush="#E4E7EC"
                        BorderThickness="1"
                        CornerRadius="12"
                        Padding="18"
                        Margin="0,0,0,12">
                    <StackPanel>
                        <TextBlock Text="About the Application"
                                   FontSize="15"
                                   FontWeight="SemiBold"
                                   Foreground="#172033"/>
                        <TextBlock TextWrapping="Wrap"
                                   Foreground="#475467"
                                   LineHeight="19"
                                   Margin="0,8,0,0"
                                   Text="Windows Shortcut Control is a lightweight productivity launcher and Windows control center designed to provide fast access to applications, files, folders, URLs, PowerShell commands, Windows administration tools, system information, and personal shortcut collections from one centralized interface."/>
                        <TextBlock TextWrapping="Wrap"
                                   Foreground="#667085"
                                   LineHeight="18"
                                   Margin="0,8,0,0"
                                   Text="The application is designed as a portable single-file Windows utility with persistent shortcut storage, recovery mechanisms, global search, Command Palette, System Tray integration, startup support, live system monitoring, backup/restore, and self-diagnostics."/>
                    </StackPanel>
                </Border>

                <Border Background="#FFFFFF"
                        BorderBrush="#E4E7EC"
                        BorderThickness="1"
                        CornerRadius="12"
                        Padding="18"
                        Margin="0,0,0,12">
                    <StackPanel>
                        <TextBlock Text="Developer &amp; Owner"
                                   FontSize="15"
                                   FontWeight="SemiBold"
                                   Foreground="#172033"
                                   Margin="0,0,0,12"/>

                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="135"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <TextBlock Grid.Row="0" Text="Name" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="0" Grid.Column="1" Text="Lathif Baska"
                                       Foreground="#172033" FontWeight="SemiBold" Margin="0,5"/>

                            <TextBlock Grid.Row="1" Text="Social Media" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="1" Grid.Column="1" Text="@baska-pro"
                                       Foreground="#172033" Margin="0,5"/>

                            <TextBlock Grid.Row="2" Text="GitHub" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="2" Grid.Column="1" Text="github.com/baska-pro"
                                       Foreground="#172033" Margin="0,5"/>

                            <TextBlock Grid.Row="3" Text="Location" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="3" Grid.Column="1" Text="Indonesia"
                                       Foreground="#172033" Margin="0,5"/>

                            <TextBlock Grid.Row="4" Text="Role" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="4" Grid.Column="1" Text="Developer, Product Owner &amp; Maintainer"
                                       Foreground="#172033" Margin="0,5"/>
                        </Grid>
                    </StackPanel>
                </Border>

                <Border Background="#FFFFFF"
                        BorderBrush="#E4E7EC"
                        BorderThickness="1"
                        CornerRadius="12"
                        Padding="18"
                        Margin="0,0,0,12">
                    <StackPanel>
                        <TextBlock Text="Application Information"
                                   FontSize="15"
                                   FontWeight="SemiBold"
                                   Foreground="#172033"
                                   Margin="0,0,0,12"/>

                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="135"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <TextBlock Grid.Row="0" Text="Created" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="0" Grid.Column="1" Text="August 27, 2026"
                                       Foreground="#172033" Margin="0,5"/>

                            <TextBlock Grid.Row="1" Text="Platform" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="1" Grid.Column="1" Text="Microsoft Windows"
                                       Foreground="#172033" Margin="0,5"/>

                            <TextBlock Grid.Row="2" Text="Technology" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="2" Grid.Column="1" Text="Windows PowerShell + WPF"
                                       Foreground="#172033" Margin="0,5"/>

                            <TextBlock Grid.Row="3" Text="Distribution" Foreground="#98A2B3" Margin="0,5"/>
                            <TextBlock Grid.Row="3" Grid.Column="1" Text="Portable Single-File Application"
                                       Foreground="#172033" Margin="0,5"/>
                        </Grid>
                    </StackPanel>
                </Border>

                <Border Background="#EFF6FF"
                        BorderBrush="#DBEAFE"
                        BorderThickness="1"
                        CornerRadius="10"
                        Padding="14">
                    <StackPanel>
                        <TextBlock Text="Ownership &amp; Copyright"
                                   FontWeight="SemiBold"
                                   Foreground="#1D4ED8"/>
                        <TextBlock TextWrapping="Wrap"
                                   Foreground="#475467"
                                   Margin="0,5,0,0"
                                   Text="© 2026 Lathif Baska. Windows Shortcut Control is developed and maintained by Lathif Baska. All rights reserved."/>
                    </StackPanel>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <Border Grid.Row="2"
                Background="#FFFFFF"
                BorderBrush="#EAECF0"
                BorderThickness="0,1,0,0"
                Padding="18,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <TextBlock Text="Windows Shortcut Control"
                           Foreground="#98A2B3"
                           FontSize="10"
                           VerticalAlignment="Center"/>

                <StackPanel Grid.Column="1"
                            Orientation="Horizontal">
                    <Button x:Name="OpenGettingStarted"
                            Content="Panduan Penggunaan"
                            Padding="12,7"
                            Margin="0,0,8,0"/>
                    <Button x:Name="OpenKeyboardShortcuts"
                            Content="Keyboard Shortcuts"
                            Padding="12,7"
                            Margin="0,0,8,0"/>
                    <Button x:Name="CloseAbout"
                            Content="Close"
                            Padding="16,7"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

        $reader = New-Object System.Xml.XmlNodeReader $aboutXaml
        $aboutWindow = [Windows.Markup.XamlReader]::Load($reader)
        $aboutWindow.Owner = $window

        $version = $aboutWindow.FindName('AboutVersion')
        $gettingStarted = $aboutWindow.FindName('OpenGettingStarted')
        $shortcutHelp = $aboutWindow.FindName('OpenKeyboardShortcuts')
        $close = $aboutWindow.FindName('CloseAbout')

        if ($null -ne $script:WindowLogoSource) {
            try { $aboutWindow.Icon = $script:WindowLogoSource } catch {}
        }

        $version.Text = "Version $($script:AppVersion)  ·  Build: Multi-Language UI + Parser Fix"

        $aboutState = [pscustomobject]@{
            Dialog = $aboutWindow
        }

        $aboutWindow.Tag = $aboutState
        $gettingStarted.Tag = $aboutState
        $shortcutHelp.Tag = $aboutState
        $close.Tag = $aboutState

        Apply-LanguageToElement $aboutWindow

        $gettingStarted.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s -or $null -eq $s.Dialog) { return }

                $s.Dialog.Hide()
                try {
                    Show-GettingStartedGuide
                }
                finally {
                    try { $s.Dialog.Show() } catch {}
                }
            } catch {
                Show-Error $_.Exception.Message (L 'About' 'About')
            }
        })

        $shortcutHelp.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s -or $null -eq $s.Dialog) { return }
                Show-KeyboardShortcutsDialog $s.Dialog
            } catch {
                Show-Error $_.Exception.Message (L 'Keyboard Shortcuts' 'Keyboard Shortcuts')
            }
        })

        $close.Add_Click({
            param($sender,$eventArgs)
            try {
                $s = $sender.Tag
                if ($null -eq $s -or $null -eq $s.Dialog) { return }
                $s.Dialog.Close()
            } catch {}
        })



        [void]$aboutWindow.ShowDialog()
    }
    catch {
        Show-Error $_.Exception.Message 'About'
    }
}

# ----------------------------
# EVENTS
# ----------------------------

# Keep the initial window comfortably inside the current Windows work area.
# This is especially useful on laptops, RDP sessions, and lower resolutions.
try {
    $workArea = [System.Windows.SystemParameters]::WorkArea

    $targetWidth = [math]::Round($workArea.Width * 0.82)
    $targetHeight = [math]::Round($workArea.Height * 0.82)

    $targetWidth = [math]::Min(980, [math]::Max(760, $targetWidth))
    $targetHeight = [math]::Min(620, [math]::Max(500, $targetHeight))

    # Never exceed the usable desktop.
    $targetWidth = [math]::Min($targetWidth, [math]::Max(700, $workArea.Width - 30))
    $targetHeight = [math]::Min($targetHeight, [math]::Max(470, $workArea.Height - 40))

    $window.Width = $targetWidth
    $window.Height = $targetHeight
    $window.MaxWidth = $workArea.Width
    $window.MaxHeight = $workArea.Height
} catch {}

$script:BtnClose.Add_Click({
    try {
        if ($null -ne $script:AppSettings -and
            [string]$script:AppSettings.CloseBehavior -eq 'Tray') {
            Hide-ToTray -ShowBalloon
        } else {
            Exit-Application
        }
    } catch {
        Exit-Application
    }
})
$script:BtnMinimize.Add_Click({ $window.WindowState = 'Minimized' })
$script:BtnMaximize.Add_Click({
    if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' }
    else { $window.WindowState = 'Maximized' }
})

$script:TopBar.Add_MouseLeftButtonDown({
    param($sender,$e)
    if ($e.ClickCount -eq 2) {
        if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' }
        else { $window.WindowState = 'Maximized' }
        return
    }
    try { $window.DragMove() } catch {}
})

$window.Add_DragOver({
    param($sender,$e)
    try {
        if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            $e.Effects = [System.Windows.DragDropEffects]::Copy
        } else {
            $e.Effects = [System.Windows.DragDropEffects]::None
        }
        $e.Handled = $true
    } catch {}
})

$window.Add_Drop({
    param($sender,$e)
    try {
        if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            $paths = [string[]]$e.Data.GetData([System.Windows.DataFormats]::FileDrop)
            Import-DroppedShortcuts $paths
            $e.Handled = $true
        }
    } catch {
        Show-Error $_.Exception.Message 'Drag & Drop'
    }
})

$script:NavDashboard.Add_Click({ Show-Page 'Dashboard' })
$script:NavShortcuts.Add_Click({ Show-Page 'Shortcuts' })
$script:NavTools.Add_Click({ Show-Page 'Tools' })
$script:NavSystem.Add_Click({ Show-Page 'System' })
$script:NavSettings.Add_Click({ Show-Page 'Settings' })

$script:BtnAddDashboard.Add_Click({ Add-ShortcutDialog })
$script:BtnAddShortcut.Add_Click({ Add-ShortcutDialog })
$script:BtnExportShortcut.Add_Click({ Export-ShortcutData })
$script:BtnImportShortcut.Add_Click({ Import-ShortcutData })

$script:TxtSearch.Add_TextChanged({ Refresh-ShortcutViews })
$script:CmbFilterType.Add_SelectionChanged({ Refresh-ShortcutViews })
$script:CmbFilterCategory.Add_SelectionChanged({
    if (-not $script:UpdatingShortcutCategory) { Refresh-ShortcutViews }
})
$script:CmbShortcutStatus.Add_SelectionChanged({ Refresh-ShortcutViews })
$script:CmbShortcutView.Add_SelectionChanged({ Refresh-ShortcutViews })

$script:TxtToolSearch.Add_TextChanged({ Refresh-ToolViews })
$script:CmbToolCategory.Add_SelectionChanged({ Refresh-ToolViews })
$script:CmbToolView.Add_SelectionChanged({ Refresh-ToolViews })

$script:TxtGlobalSearch.Add_TextChanged({ Refresh-GlobalSearch })
$script:BtnClearGlobalSearch.Add_Click({
    $script:TxtGlobalSearch.Clear()
    $script:TxtGlobalSearch.Focus() | Out-Null
})

$script:BtnRefreshSystem.Add_Click({ Refresh-SystemInfo })

$script:CmbLanguage.Add_SelectionChanged({
    try {
        if ($script:UpdatingSettings) { return }
        if ($null -eq $script:CmbLanguage.SelectedItem) { return }

        $lang = [string]$script:CmbLanguage.SelectedItem.Tag
        if ($lang -notin @('id','en')) { return }

        if ($null -eq $script:AppSettings) { Load-AppSettings }
        $script:AppSettings.Language = $lang
        Save-AppSettings
        Apply-AppLanguage
        Apply-SettingsToUI
        Set-Status (L 'Bahasa aplikasi diperbarui.' 'Application language updated.')
    } catch {
        Show-Error $_.Exception.Message (L 'Bahasa' 'Language')
    }
})

$script:BtnSaveSettings.Add_Click({
    Save-SettingsFromUI
})

$script:BtnMinimizeToTray.Add_Click({
    Hide-ToTray -ShowBalloon
})

$script:BtnExportFullConfig.Add_Click({
    Export-AppConfiguration
})

$script:BtnImportFullConfig.Add_Click({
    Import-AppConfiguration
})

$script:BtnOpenGettingStarted.Add_Click({
    Show-GettingStartedGuide
})

$script:BtnRunDiagnostics.Add_Click({
    try {
        $results = @(Get-SelfDiagnosticResults)
        $ok = @($results | Where-Object { $_.Status -eq 'OK' }).Count
        $warn = @($results | Where-Object { $_.Status -in @('WARN','INFO') }).Count
        $fail = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count

        $script:TxtDiagnosticsSummary.Text = "OK: $ok · Warning/Info: $warn · Fail: $fail"

        if ($fail -gt 0) {
            $script:TxtDiagnosticsSummary.Foreground = '#B42318'
        }
        elseif ($warn -gt 0) {
            $script:TxtDiagnosticsSummary.Foreground = '#B54708'
        }
        else {
            $script:TxtDiagnosticsSummary.Foreground = '#15803D'
        }

        Show-SelfDiagnostics
    }
    catch {
        Show-Error $_.Exception.Message 'Self Diagnostics'
    }
})


$script:BtnOpenScriptFolder.Add_Click({
    try {
        $selfPath = [Environment]::GetEnvironmentVariable('LAVI_CONTROL_CENTER_SELF')
        $path = if (-not [string]::IsNullOrWhiteSpace($selfPath)) {
            Split-Path -Parent $selfPath
        } elseif ($PSScriptRoot) {
            $PSScriptRoot
        } else {
            (Get-Location).Path
        }
        Start-Process explorer.exe -ArgumentList "`"$path`""
    } catch { Show-Error $_.Exception.Message }
})

$script:BtnAbout.Add_Click({
    Show-AboutDialog
})

# Keyboard shortcuts
$window.Add_KeyDown({
    param($sender,$e)

    try {
        $mods = [System.Windows.Input.Keyboard]::Modifiers
        $ctrl = (($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)
        $shift = (($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0)
        $alt = (($mods -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0)

        # Alt navigation. WPF reports Alt combinations through SystemKey.
        if ($alt -and -not $ctrl) {
            $navKey = if ($e.Key -eq [System.Windows.Input.Key]::System) {
                $e.SystemKey
            } else {
                $e.Key
            }

            switch ($navKey) {
                'D1'      { Show-Page 'Dashboard'; $e.Handled = $true }
                'NumPad1' { Show-Page 'Dashboard'; $e.Handled = $true }

                'D2'      { Show-Page 'Shortcuts'; $e.Handled = $true }
                'NumPad2' { Show-Page 'Shortcuts'; $e.Handled = $true }

                'D3'      { Show-Page 'Tools'; $e.Handled = $true }
                'NumPad3' { Show-Page 'Tools'; $e.Handled = $true }

                'D4'      { Show-Page 'System'; $e.Handled = $true }
                'NumPad4' { Show-Page 'System'; $e.Handled = $true }

                'D5'      { Show-Page 'Settings'; $e.Handled = $true }
                'NumPad5' { Show-Page 'Settings'; $e.Handled = $true }
            }

            if ($e.Handled) { return }
        }

        if ($ctrl) {
            switch ($e.Key) {
                'N' {
                    if (-not $shift) {
                        Add-ShortcutDialog
                        $e.Handled = $true
                    }
                }

                'K' {
                    if (-not $shift) {
                        Show-CommandPalette
                        $e.Handled = $true
                    }
                }

                'F' {
                    if ($shift) {
                        Show-Page 'Shortcuts'
                        $script:TxtSearch.Focus() | Out-Null
                        $script:TxtSearch.SelectAll()
                    }
                    else {
                        $script:TxtGlobalSearch.Focus() | Out-Null
                        $script:TxtGlobalSearch.SelectAll()
                    }
                    $e.Handled = $true
                }

                'E' {
                    if (-not $shift) {
                        Export-ShortcutData
                        $e.Handled = $true
                    }
                }

                'I' {
                    if (-not $shift) {
                        Import-ShortcutData
                        $e.Handled = $true
                    }
                }

                'B' {
                    if ($shift) {
                        Import-AppConfiguration
                    }
                    else {
                        Export-AppConfiguration
                    }
                    $e.Handled = $true
                }

                'A' {
                    if ($shift) {
                        Show-AboutDialog
                        $e.Handled = $true
                    }
                }

                'D' {
                    if ($shift) {
                        Show-SelfDiagnostics
                        $e.Handled = $true
                    }
                }

                'T' {
                    if ($shift) {
                        [void](Hide-ToTray -ShowBalloon)
                        $e.Handled = $true
                    }
                }

                'OemComma' {
                    if (-not $shift) {
                        Show-Page 'Settings'
                        $e.Handled = $true
                    }
                }
            }

            if ($e.Handled) { return }
        }

        if ($e.Key -eq 'F1') {
            Show-GettingStartedGuide
            $e.Handled = $true
            return
        }

        if ($e.Key -eq 'F5') {
            Refresh-ShortcutViews
            Refresh-ToolViews

            if ($script:LastPage -eq 'System') {
                Refresh-SystemInfo
            }

            if (-not [string]::IsNullOrWhiteSpace($script:TxtGlobalSearch.Text)) {
                Refresh-GlobalSearch
            }

            Set-Status 'Tampilan diperbarui.'
            $e.Handled = $true
        }
    }
    catch {
        Show-Error $_.Exception.Message 'Keyboard Shortcut'
    }
})

$window.Add_Closing({
    param($sender,$e)

    try {
        if (-not $script:AllowWindowClose -and
            $null -ne $script:AppSettings -and
            [string]$script:AppSettings.CloseBehavior -eq 'Tray') {

            $e.Cancel = $true
            Hide-ToTray
        }
    } catch {}
})

# Single-instance activation bridge.
# If the app is already running in tray, double-clicking the .cmd again
# signals this instance and reopens the main window.
if ($null -ne $script:ActivationEvent) {
    $script:ActivationTimer = New-Object Windows.Threading.DispatcherTimer
    $script:ActivationTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:ActivationTimer.Add_Tick({
        try {
            if ($null -ne $script:ActivationEvent -and
                $script:ActivationEvent.WaitOne(0)) {

                Show-MainWindow
                Set-Status 'Aplikasi diaktifkan dari peluncuran kedua.'
            }
        } catch {}
    })
    $script:ActivationTimer.Start()
}

# Live clock
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    $now = Get-Date
    $script:TxtTime.Text = $now.ToString('HH:mm:ss')
    $script:TxtDate.Text = $now.ToString('dddd, dd MMMM yyyy')
    $script:TxtStatusRight.Text = "$env:COMPUTERNAME  •  $env:USERNAME"
})
$timer.Start()

# Startup
$script:TxtComputer.Text = $env:COMPUTERNAME
$script:TxtUser.Text = $env:USERNAME

Load-AppSettings

# Repair an older v2.6 startup entry automatically so future logins include
# the --startup flag and point to the currently running fixed file.
if ($null -ne $script:AppSettings -and [bool]$script:AppSettings.RunAtStartup) {
    try { [void](Set-StartupRegistration $true) } catch {}
}

Initialize-BackgroundRunspacePool
Initialize-ShortcutStore
Build-Tools
Initialize-AppLogo | Out-Null
Apply-SettingsToUI
Apply-AppLanguage

$window.Add_SourceInitialized({
    try {
        Apply-GlobalHotkeySetting
    } catch {}
})

$window.Add_ContentRendered({
    try {
        $trayReady = Initialize-SystemTray
        if ($trayReady) { Start-TrayKeepAlive }

        if ($script:IsStartupLaunch -and
            $null -ne $script:AppSettings -and
            [bool]$script:AppSettings.StartInTray) {

            if ($trayReady) {
                [void](Hide-ToTray)
            }
            else {
                # Never hide when tray creation fails.
                Show-MainWindow
                Set-Status 'Start in Tray dibatalkan karena tray tidak tersedia.'
            }
        }
        else {
            # Manual double-click must always show the main window, even when
            # "Mulai langsung di System Tray" is enabled in Settings.
            Show-MainWindow
        }
    } catch {
        try { Show-MainWindow } catch {}
    }
})

# First-run guided tour. It is delayed slightly so the main window is fully
# rendered before the modal guide appears.
try {
    if (-not $script:IsStartupLaunch -and
        $null -ne $script:AppSettings -and
        -not [bool]$script:AppSettings.OnboardingCompleted) {

        $script:FirstRunGuideTimer = New-Object Windows.Threading.DispatcherTimer
        $script:FirstRunGuideTimer.Interval = [TimeSpan]::FromMilliseconds(650)
        $script:FirstRunGuideTimer.Add_Tick({
            try {
                $script:FirstRunGuideTimer.Stop()
                Show-FirstRunGuideIfNeeded
            } catch {}
        })
        $script:FirstRunGuideTimer.Start()
    }
} catch {}

# Preload system data in background so opening System Info is usually instant.
Start-SystemInfoBackgroundLoad

try {
    Refresh-ShortcutViews
} catch {
    # One malformed shortcut must not prevent the application from opening.
    Set-Status ('Peringatan saat memuat shortcut: ' + $_.Exception.Message)
}
Show-Page 'Dashboard'

$window.Add_Closed({
    try { $timer.Stop() } catch {}
    try {
        if ($null -ne $script:TrayKeepAliveTimer) {
            $script:TrayKeepAliveTimer.Stop()
        }
    } catch {}
    try {
        if ($null -ne $script:FirstRunGuideTimer) {
            $script:FirstRunGuideTimer.Stop()
        }
    } catch {}
    try {
        if ($null -ne $script:ActivationTimer) {
            $script:ActivationTimer.Stop()
        }
    } catch {}
    try {
        if ($null -ne $script:ActivationEvent) {
            $script:ActivationEvent.Dispose()
            $script:ActivationEvent = $null
        }
    } catch {}
    try { Dispose-GlobalHotkeyInterop } catch {}
    try { Dispose-SystemTray } catch {}
    try { Dispose-AppLogo } catch {}
    try {
        if ($null -ne $script:SystemInfoPollTimer) {
            $script:SystemInfoPollTimer.Stop()
        }
    } catch {}
    try { Stop-SystemMonitor } catch {}
    try {
        if ($null -ne $script:SystemMonitorTimer) {
            $script:SystemMonitorTimer.Stop()
        }
    } catch {}
    try { Dispose-BackgroundRunspacePool } catch {}
    try {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown(
            [System.Windows.Threading.DispatcherPriority]::Background
        )
    } catch {}

    try {
        if ($null -ne $script:AppMutex) {
            if ($script:OwnsAppMutex) {
                try { $script:AppMutex.ReleaseMutex() } catch {}
            }
            $script:AppMutex.Dispose()
        }
    } catch {}
})

# Persistent WPF message loop.
# Do NOT use ShowDialog here: the app must remain alive while the main
# window is hidden in System Tray.
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
