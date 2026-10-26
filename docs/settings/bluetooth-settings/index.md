# Bluetooth Settings Overview

The plugin provides Bluetooth management for compatible Kobo devices (Libra 2, Libra Colour, Clara
BW/Colour, Elipsa 2E), allowing you to pair devices, connect to them, and configure button mappings
for Bluetooth remotes and keyboards.

## Documentation

- **[Paired Devices](./paired-devices.md)**: Managing paired Bluetooth devices and connections
- **[Device Options Menu](./device-options-menu.md)**: Available actions for individual devices
- **[Key Bindings](./key-bindings.md)**: Configuring button mappings for Bluetooth devices
- **[Auto-Detection](./auto-detection.md)**: Settings for automatically detecting reconnecting
  devices
- **[Auto-Connect](./auto-connect.md)**: Settings for automatically connecting to nearby paired
  devices
- **[Enable on Startup](./enable-on-startup.md)**: Turn Bluetooth on when KOReader starts
- **[Device Ready Notifications](./device-ready-notifications.md)**: Control notifications when
  devices connect
- **[Swap Page-Turn Buttons When Inverted](./swap-page-turn-when-inverted.md)**: Reverse the
  page-turn buttons of a remote while the screen is rotated 180°
- **[Menu Navigation](./menu.md)**: How to access Bluetooth settings and menu hierarchy reference

## Prevent exiting while Bluetooth is on

Enabled by default under Settings → Network → Bluetooth → Settings. While Bluetooth is powered
on, the plugin disables the Exit menu item and blocks Exit commands from gestures and keyboard
bindings. Turn Bluetooth off to exit normally, or disable this setting to allow Exit at any time.

Restart, sleep, reboot, power-off and direct calls to KOReader's quit function are unchanged.
This feature is part of the plugin; no separate user patch is required. Remove
`2-disable-exit-while-bluetooth-on.lua` from KOReader's patches directory if you previously
installed the standalone version, then restart KOReader.
