# MemoryDock

A lightweight, native SwiftUI macOS utility for managing **RAM, running apps, browser tabs, databases/background services, external drives, Wi-Fi (SMB/AFP) disks, and local files** from one dashboard and menu bar icon.

Built specifically to keep overhead low on **8 GB / 16 GB Macs** (~50–130 MB RAM, <2% idle CPU).

---

## Features

### 1. Menu Bar & Live RAM Monitor
- Live RAM usage indicator in the macOS menu bar (`X.X / 8 GB`).
- Real-time breakdown of **Active, Wired, Compressed, and Free/Reclaimable** memory via Mach `host_statistics64`.
- **Launch at Login** toggle (`SMAppService`).

### 2. Running Apps & One-Click "Low RAM Mode"
- Lists open macOS GUI apps sorted by total RSS memory (including helper/renderer subprocesses).
- **Pin / Protect** essential apps (e.g., Finder, Terminal, your IDE) so **Low RAM Mode** never closes them.
- **Quit** or **Force Quit** any app in one click.

### 3. Browser Tab Manager
- Lists open tabs across **Google Chrome**, **Brave**, and **Safari**.
- Close individual tabs or **Close All Inactive Tabs** at once.

### 4. Databases & Background Services
- Detects running databases and background agents (**MySQL**, **PostgreSQL**, **Redis**, **MongoDB**, **Homebrew services**, **Gradle Daemon**, **Ollama**, **OpenClaw Gateway**).
- Start or stop services with one click.

### 5. Disk Management & External App Mover
- Auto-refreshing list of **Internal SSD**, **External USB drives**, and **Wi-Fi network disks** (with live mount/unmount detection).
- **Move Apps to External Drive** (and **Move Back to Internal SSD**) with automatic symlinks, live **progress %**, and **MB/s transfer speed**.
- **Safe Eject Guard** that prevents ejecting a drive while an app is running from it.
- Move **Desktop, Downloads & Documents** contents to any writable disk with progress tracking.

### 6. Wi-Fi / Network Disks (SMB / AFP)
- Auto-discover SMB & AFP shares on your local Wi-Fi network via Bonjour, or connect manually (`smb://host/share`).
- Built-in **Volume Browser** to browse folders, create folders, upload files with progress/speed, open files, or permanently delete files.

### 7. File Organizer, Image Preview & Duplicate Finder
- Scans **Desktop**, **Downloads**, and **Documents** and categorizes files into **Documents, Images, Videos, Audio, Archives, and Other**.
- Lightweight `ImageIO` **thumbnails & full image preview**.
- **Duplicate Finder** (SHA-256 content match) and **> 50 MB Large File Radar**.
- **Move Category to Disk** or **Permanent Delete** (with confirmation alert).

---

## Requirements

- **macOS 14.0 (Sonoma)** or later
- **Swift 6.0+** / **Xcode Command Line Tools**

## Build & Run

```bash
git clone https://github.com/<your-username>/MemoryDock.git
cd MemoryDock
./build_app.sh
open dist/MemoryDock.app
```

You can also pass a custom install path:

```bash
./build_app.sh /Applications/MemoryDock.app
```

## Permissions

Depending on which features you use, macOS may prompt once for:
- **Automation** (to list/close tabs in Chrome, Brave, or Safari)
- **Files and Folders** (to scan/move files in Desktop, Downloads, or Documents)
- **Administrator Password** (only when stopping root-owned services like MySQL or moving root-owned apps like Xcode)

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
