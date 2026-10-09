# ddevDock

[![CI](https://github.com/DenisStetsenko/ddevDock/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/DenisStetsenko/ddevDock/actions/workflows/ci.yaml?query=branch:main)
[![Release](https://img.shields.io/github/v/release/DenisStetsenko/ddevDock)](https://github.com/DenisStetsenko/ddevDock/releases)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)](#install)
[![License](https://img.shields.io/github/license/DenisStetsenko/ddevDock)](LICENSE)

A tiny macOS menu bar app for [DDEV](https://ddev.com). It shows your projects, how many are running, and lets you start, stop, SSH into or open them without leaving the menu bar.

Single Swift file, AppKit only, no dependencies. macOS 15 or later.

## Features

- Project list with a colored status dot: green running, gray stopped, red unhealthy or misconfigured.
- Running-project count next to the menu bar icon.
- Per project: Start / Stop, Restart, Open URL, SSH (opens your terminal), Mailpit, Open in Finder, Favorites, Archive.
- Favorites are pinned to the top; archived projects move into an `Archived` submenu so the main list stays short.
- Stop All (`ddev poweroff`).
- Live menu: statuses update while the menu is open.
- Notification when a running project becomes unhealthy.
- Launch at Login.
- Settings window: terminal app and poll interval.

## Install

Requires Xcode command line tools and `ddev` in `/opt/homebrew/bin` or `/usr/local/bin`.

```sh
make app       # builds ddevDock.app in the repo
make install   # copies it to /Applications
open /Applications/ddevDock.app
```

On first launch macOS asks for notification permission. The first SSH asks for permission to control your terminal.

## Settings

Open `Settings…` from the menu.

| Setting | Default | Notes |
|---|---|---|
| Terminal app | Terminal | Must support the AppleScript `do script` command (Terminal does, iTerm does not). |
| Refresh every (s) | 30 | Minimum 5. Opening the menu and running a command refresh immediately regardless. |

## How it works

The app runs `ddev list -j` on a background queue and caches the result. The menu is built from that cache, never from a live call, so it opens instantly. The cache refreshes on a timer, when the menu opens, and after every command. Polling pauses while the screen is asleep.

Commands run through `/usr/bin/env ddev` with Homebrew paths prepended, since GUI apps do not inherit the shell `PATH`. A non-zero exit shows the last lines of output in an alert. Telemetry is disabled for calls made by the app (`DDEV_NO_INSTRUMENTATION=true`), so the background poll does not flood DDEV's stats.

## Development

```sh
swift build    # debug build
swift run      # run without a bundle: no notifications, no Launch at Login
make clean
```

Everything lives in `Sources/ddevDock/main.swift`. The bundle layout, icon and `Info.plist` are assembled by the `Makefile`; the `.app` is ad-hoc signed, good for local use only.

## License

MIT, see [LICENSE](LICENSE).
