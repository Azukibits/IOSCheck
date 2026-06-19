# IOSCheck

[简体中文](README.zh-CN.md)

`IOSCheck` is a native `macOS` app for managing multiple Apple accounts and reducing repetitive login input.

It does not bypass Apple's protected sign-in flow. Instead, it focuses on a safer and realistic workflow:

- store account metadata locally
- keep passwords in `macOS Keychain`
- copy or auto-fill `Apple ID` / password into the currently focused macOS input field

## Features

- Native `AppKit` GUI
- Multiple Apple account profiles
- Passwords stored with `Security.framework`
- One-click copy for `Apple ID`
- One-click copy for password
- Auto-paste `Apple ID` after a short delay
- Auto-paste password after a short delay
- Clipboard auto-clear for passwords after `60` seconds

## Security

- Account metadata and passwords are intentionally separated
- Local file stores only alias and `Apple ID`
- Passwords are written to system `Keychain`
- Local config directory is restricted to the current user
- Passwords are not permanently shown in the main UI
- Sensitive clipboard content is cleared automatically after `60` seconds

## Auto-Paste

`IOSCheck` can auto-fill the currently focused macOS input field by:

1. copying `Apple ID` to the clipboard, then sending `Cmd+V`
2. simulating password typing through macOS accessibility automation
3. giving you a short delay to switch focus first

Requirements:

- macOS Accessibility permission must be granted to `IOSCheck`
- the target must be a macOS input field that accepts keyboard input

This is useful for desktop login forms or macOS app windows.

## Limitations

- It cannot directly switch `iCloud` on `iPhone` or `iPad`
- It cannot directly complete protected Apple sign-in flows on iOS
- It cannot force typing into fields that block accessibility-driven input

If the target is Apple's protected system UI on mobile devices, third-party apps do not have the required control surface.

## Build

```bash
cmake -S . -B build
cmake --build build
```

If `cmake` is not in `PATH`:

```bash
/Applications/CLion.app/Contents/bin/cmake/mac/aarch64/bin/cmake -S . -B build
/Applications/CLion.app/Contents/bin/cmake/mac/aarch64/bin/cmake --build build
```

Output:

```text
build/IOSCheck.app
```

## First Launch

The current public build is not yet signed and notarized with an Apple Developer certificate.

If macOS shows "damaged" or "cannot verify developer" after downloading from GitHub, that is usually `Gatekeeper` blocking an unsigned app rather than a broken bundle.

Workaround:

1. Open the `.dmg`
2. Drag `IOSCheck.app` into `Applications`
3. Run `Open IOSCheck.command`

That helper script attempts to remove the quarantine flag and launch the app.

## Tech Stack

- `Objective-C++`
- `AppKit`
- `Security.framework`
- `CMake`
