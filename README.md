# Android File Transfer

[![GitHub license](https://img.shields.io/github/license/5j54d93/Android-File-Transfer)](https://github.com/5j54d93/Android-File-Transfer/blob/main/LICENSE)
![GitHub Repo stars](https://img.shields.io/github/stars/5j54d93/Android-File-Transfer)
![GitHub repo size](https://img.shields.io/github/repo-size/5j54d93/Android-File-Transfer)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)

A macOS app built with SwiftUI to browse Android devices and move files both ways over USB (MTP) and Wi-Fi (ADB) — a fast, Finder-like replacement for Google's discontinued Android File Transfer.

<img src="https://github.com/5j54d93/Android-File-Transfer/blob/main/.github/Assets/main.png" width='100%' height='100%'/>

## Overview

1. [**Browse**](https://github.com/5j54d93/Android-File-Transfer#browse)
2. [**Transfer Files**](https://github.com/5j54d93/Android-File-Transfer#transfer-files)
3. [**Connect over Wi-Fi**](https://github.com/5j54d93/Android-File-Transfer#connect-over-wi-fi)
4. [**Under the Hood**](https://github.com/5j54d93/Android-File-Transfer#under-the-hood)
5. [**Requirements**](https://github.com/5j54d93/Android-File-Transfer#requirements)
6. [**License**](https://github.com/5j54d93/Android-File-Transfer#licensemit)

## Browse

A Finder-style source list of devices and storages on the left, and a multi-column file table (Name / Size / Kind / Date Modified) with a clickable breadcrumb path bar on the right.

- **Live sync**：the list updates the instant a file is added or removed on the device — no refresh, no reopen.
- **Storage gauge**：the path bar shows used / free percentage, turning orange then red as the device fills up.
- **Finder conventions**：double-click to open a folder, <kbd>Return</kbd> to rename, right-click empty space for **New Folder**, and create / rename / delete inline.

<img src="https://github.com/5j54d93/Android-File-Transfer/blob/main/.github/Assets/browse.png" width='100%' height='100%'/>

## Transfer Files

Drag files from Finder onto the window to upload, and drag files out to Finder to download — both directions stream in the background.

- **File promises**：dragging a file out completes the gesture instantly and downloads in the background to wherever you drop it, instead of freezing while the whole file copies.
- **Multi-file drag**：select several files and drag them all out at once.
- **Transfer queue**：a live progress ring on the toolbar, with per-item speed, ETA, cancel, and retry-on-failure.
- **Large files**：handles files larger than 4 GB in both directions.

<img src="https://github.com/5j54d93/Android-File-Transfer/blob/main/.github/Assets/transfer.gif" width='100%' height='100%'/>

## Connect over Wi-Fi

No cable? Pair once and browse the device wirelessly — `adb` is bundled, so there's nothing to install.

- **Three ways to pair**：scan a QR code, type a pairing code, or connect directly by IP : port from the phone's Wireless debugging screen.
- **Auto-discovery**：paired devices on the same network are found over mDNS and connected automatically.
- **USB wins**：the same phone reached over both USB and Wi-Fi is de-duplicated into a single device.

<img src="https://github.com/5j54d93/Android-File-Transfer/blob/main/.github/Assets/pairing.png" width='100%' height='100%'/>

## Under the Hood

- **MTPKit**：a dependency-free Swift package that speaks the MTP protocol directly over `IOUSBHost` (no `libmtp`), alongside an ADB-over-Wi-Fi transport — both behind one shared `DeviceTransport` abstraction.
- **SwiftUI + Observation**：`@Observable` view models throughout, with `async`/`await` and actors serializing all USB / ADB I/O.
- **Localized**：English and 繁體中文 via String Catalogs.
- **Zero third-party dependencies**：QR codes via Core Image, discovery via the Network framework, USB via `IOUSBHost`.

## Requirements

- macOS 26 or later
- An Android device — a USB cable, or Wi-Fi with Wireless debugging enabled
- Xcode 26 or later to build：open `Android-File-Transfer.xcodeproj` and run

## License：MIT

This package is [MIT licensed](https://github.com/5j54d93/Android-File-Transfer/blob/main/LICENSE).
