# Android File Transfer

[![GitHub license](https://img.shields.io/github/license/5j54d93/Android-File-Transfer)](https://github.com/5j54d93/Android-File-Transfer/blob/main/LICENSE)
![GitHub Repo stars](https://img.shields.io/github/stars/5j54d93/Android-File-Transfer)
![GitHub repo size](https://img.shields.io/github/repo-size/5j54d93/Android-File-Transfer)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)

A fast, native macOS app for transferring files between your Mac and Android device over USB（MTP）or Wi-Fi（ADB）：a Finder-like, open-source replacement for Google's discontinued Android File Transfer. Built with SwiftUI.

<img src="https://github.com/5j54d93/Android-File-Transfer/blob/main/.github/Assets/main.png" width='100%' height='100%'/>

## Overview

1. [**Browse**](https://github.com/5j54d93/Android-File-Transfer#browse)
2. [**Transfer Files**](https://github.com/5j54d93/Android-File-Transfer#transfer-files)
3. [**Connect over Wi-Fi**](https://github.com/5j54d93/Android-File-Transfer#connect-over-wi-fi)
4. [**When Something Goes Wrong**](https://github.com/5j54d93/Android-File-Transfer#when-something-goes-wrong)
5. [**Under the Hood**](https://github.com/5j54d93/Android-File-Transfer#under-the-hood)
6. [**Requirements**](https://github.com/5j54d93/Android-File-Transfer#requirements)
7. [**License**](https://github.com/5j54d93/Android-File-Transfer#licensemit)

## Browse

A Finder-style source list of devices and storages on the left, and a multi-column file table（Name／Size／Kind／Date Modified）with a clickable breadcrumb path bar on the right.

- **Live sync**：device-side changes appear automatically — events pushed by the phone plus a background re-check（every 3 s by default）keep the list current with no manual refresh.
- **Auto-refresh, your way**：a status dot under the window title shows whether background refresh is on（green）or off（red）. Tune its interval（1–60 s）or turn it off entirely in **Settings**（<kbd>⌘</kbd><kbd>,</kbd>）— pushed events and manual refresh keep working either way.
- **Instant navigation**：folders you've already opened reopen instantly from cache — no loading spinner — while refreshing in the background to stay current.
- **Storage gauge**：the path bar shows used／free percentage plus the free space available, turning orange then red as the device fills up.
- **Finder conventions**：double-click to open a folder, <kbd>Return</kbd> to rename, right-click empty space for **New Folder**, and create／rename／delete inline.

## Transfer Files

Drag files from Finder onto the window to upload, and drag files out to Finder to download — both directions stream in the background.

- **File promises**：dragging a file out completes the gesture instantly and downloads in the background to wherever you drop it, instead of freezing while the whole file copies.
- **Multi-file drag**：select several files and drag them all out at once.
- **Full-window progress**：a transfer dims the entire window — toolbar included — behind a centered card with phase steps（Prepare ▸ Transfer ▸ Complete）, the current file and destination, overall progress, speed, and ETA. The final phase reads "Waiting for phone to confirm", so a finishing upload never looks stuck, and the card clears itself the moment everything is done — failures stay on screen with **Retry All**.
- **Large files**：handles files larger than 4 GB in both directions.

<img src="https://github.com/5j54d93/Android-File-Transfer/blob/main/.github/Assets/transfer.gif" width='100%' height='100%'/>

## Connect over Wi-Fi

No cable? Pair once and browse the device wirelessly — `adb` is bundled, so there's nothing to install.

- **Three ways to pair**：scan a QR code, type a pairing code, or connect directly by IP : port from the phone's Wireless debugging screen.
- **Auto-discovery**：paired devices on the same network are found over mDNS and connected automatically.
- **USB wins**：the same phone reached over both USB and Wi-Fi is de-duplicated into a single device.

<img src="https://github.com/5j54d93/Android-File-Transfer/blob/main/.github/Assets/pairing.png" width='100%' height='100%'/>

## When Something Goes Wrong

Failures are explained and recoverable in the window — not buried in a log.

- **Centered alerts**：errors appear as a modal card with the reason and a clear next step, never a banner that slides away on its own.
- **One-click reconnect**：if the USB connection wedges mid-session, the alert offers **Reconnect** — reset the device, re-discover, reload.
- **"Photos" conflict detection**：when Photos or Image Capture is holding the device（the classic reason MTP apps can't connect）, the app names the culprit and offers **Quit and Rescan**.

## Under the Hood

- **[MTPKit](https://github.com/5j54d93/MTPKit)**：a standalone, dependency-free Swift package that speaks the MTP protocol directly over `IOUSBHost`（no `libmtp`）, alongside an ADB-over-Wi-Fi transport — both behind one shared `DeviceTransport` abstraction. The app pulls it in via Swift Package Manager. Includes the USB-level reliability work — zero-length-packet termination and automatic endpoint-stall recovery — that cures the classic "upload of a certain size hangs, then the connection dies" MTP failure.
- **SwiftUI + Observation**：`@Observable` view models throughout, with `async`／`await` and actors serializing all USB／ADB I/O — and every device round-trip runs off the main actor, so the UI never freezes behind device I/O.
- **Performance, learned the hard way**：no Liquid Glass or large blurred shadows on the transfer overlay（their offscreen GPU passes stalled CoreAnimation commits）, background polling pauses during transfers and while the app is in the background, and listings are cached for instant back-navigation.
- **Localized**：English and 繁體中文 via String Catalogs.
- **Zero third-party dependencies**：QR codes via Core Image, discovery via the Network framework, USB via `IOUSBHost`.

## Requirements

- macOS 26 or later
- An Android device — a USB cable, or Wi-Fi with Wireless debugging enabled
- Xcode 26 or later to build：open `Android-File-Transfer.xcodeproj` and run

## License：MIT

This package is [MIT licensed](https://github.com/5j54d93/Android-File-Transfer/blob/main/LICENSE).
