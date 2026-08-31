# Studio Switch

Studio Switch is a native macOS menu-bar utility that makes an Apple keyboard,
mouse, or trackpad follow an Apple Studio Display between two Macs.

It deliberately needs no network connection. When the Studio Display is
unplugged, the old Mac releases the selected Bluetooth devices. When the display
appears on the other Mac, that Mac repeatedly asks the already-paired devices to
connect. This makes the Thunderbolt cable act as the switch.

## Setup

1. Pair the keyboard and mouse/trackpad with **both Macs** once in System Settings.
2. Build and install Studio Switch on each Mac:

   ```sh
   make install
   ```

3. Open **Studio Switch** from Applications on each Mac.
4. Select the same keyboard and mouse/trackpad in the menu-bar panel.
5. Enable **Launch at login** on both Macs.

The default display match is `Studio Display`. It can be changed in the panel if
macOS reports a different localized display name.

Studio Switch stays visible in the menu bar while it is running. Its display icon
has a gray dot while waiting, an orange dot while switching, and a green dot when
the Studio Display is attached.

If the icon is not visible after launching, first check whether macOS has hidden
it because the menu bar is crowded (especially on a MacBook with a notch). Quit
other menu-bar utilities temporarily to make space. Studio Switch uses a native
AppKit status item and does not create a Dock icon.

## Development

The project is a Swift Package so it can be built with Command Line Tools alone:

```sh
swift build
swift run StudioSwitch
```

`make app` creates an ad-hoc signed app at `build/Studio Switch.app`.

## Notes

- Devices must remain paired with both Macs; Studio Switch connects and
  disconnects them but does not alter pairing records.
- Keep a built-in laptop keyboard/trackpad available during initial setup.
- `Launch at login` requires running the packaged app rather than `swift run`.
