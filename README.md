# BeyondBrightness

BeyondBrightness is a small macOS menu bar app for pushing supported built-in displays past the usual `100%` brightness limit.

It is designed for newer MacBook Pro panels that support Apple's extended dynamic range behavior. On supported hardware, BeyondBrightness can move from normal brightness into a boosted range that feels closer to the "Native XDR brightness upscaling" behavior found in other display tools.

## What You Get

- A menu bar control for display brightness
- Support for values above `100%` on compatible displays
- A small notification when brightness changes
- Menu bar display modes for `Icon + %`, `Icon only`, or `Hidden`

## How It Works

Up to `100%`, the app uses the normal macOS brightness controls.

Above `100%`, BeyondBrightness uses a mix of private display APIs and an HDR/XDR-style overlay technique to activate extra perceived brightness on supported displays.

If your Mac does not support the boosted path, the app falls back to standard brightness control.

## Using The App

1. Launch `BeyondBrightness.app`.
2. Click the menu bar item.
3. Drag the slider or choose a preset like `120%` or `160%`.
4. Open `Settings` if you want to change how the app appears in the menu bar.

## Installation

1. Download the latest `BeyondBrightness.dmg` release build.
2. Open the disk image.
3. Drag `BeyondBrightness.app` into `Applications`.
4. Launch the app from `Applications`.

## Requirements

- macOS 14 or newer
- A Mac display that supports the boosted brightness path

## Permissions

Brightness control itself does not require a special macOS permission.

The only user-facing permission BeyondBrightness may request is notification permission, if you want brightness change notifications to appear.

## Important Notes

- BeyondBrightness uses private Apple APIs, so behavior may change across macOS releases.
- Boosted brightness is hardware dependent and may behave differently across Mac models.
- Running a display above its normal brightness range will usually increase power usage and can reduce battery life noticeably.
- Extended use at elevated brightness levels may contribute to faster long-term display wear or degradation.
- This app is intended for personal use and experimentation on supported Macs.

## Build From Source

```bash
chmod +x ./build.sh
./build.sh
```

The built app will be available at `./Build/BeyondBrightness.app`.
