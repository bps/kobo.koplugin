<div align="center">

# kobo.koplugin

A KoReader plugin that extends Kobo device functionality.

</div>

## Features

- **Virtual Library** - Browse and open your Kobo kepub collection directly from KOReader
- **Reading State Sync** - Bidirectional synchronization of reading progress between KOReader and
  Kobo
- **Bluetooth Support** - Manage Bluetooth connections and pair devices from within KOReader

For detailed documentation of the original plugin, visit
[ogkevin.github.io/kobo.koplugin](https://ogkevin.github.io/kobo.koplugin).

## About this fork

This is a fork of [OGKevin/kobo.koplugin](https://github.com/OGKevin/kobo.koplugin). The plugin,
including all of its Bluetooth support, is the work of [OGKevin](https://github.com/OGKevin) and its
contributors. It is distributed under the same licence as the original, the
[GNU General Public License v3.0](LICENSE).

The fork exists to use a cheap Bluetooth ring remote as a page turner on a Kobo Clara BW. Everything
it added is now upstream or proposed there, so this branch is the upstream `main` branch plus the
open pull requests, with nothing else on top:

- Support for Bluetooth remotes that emulate a touch screen ("TikTok rings"): merged upstream as
  [pull request #237](https://github.com/OGKevin/kobo.koplugin/pull/237). See
  [Bluetooth](docs/features/bluetooth.md) and
  [touch-screen remotes](docs/dev/bluetooth/touch-screen-remotes.md).
- Bluetooth on MediaTek Kobos without borrowing a Wi-Fi connection, including the radio bring-up on
  a cold boot: open as [pull request #238](https://github.com/OGKevin/kobo.koplugin/pull/238).
- Faster auto-connect after Bluetooth comes on, several paired remotes of the same model, and the
  "Enable on startup" setting: open as
  [pull request #240](https://github.com/OGKevin/kobo.koplugin/pull/240). See
  [auto-connect](docs/settings/bluetooth-settings/auto-connect.md) and
  [enable on startup](docs/settings/bluetooth-settings/enable-on-startup.md).

### The setup this fork was written for

The remote sits in a 3D-printed case with thumb buttons for the Kobo Clara BW / Colour, so pages
turn without touching the screen. The case and the instructions for fitting a cheap ring remote into
it are on MakerWorld: [Kobo Clara BW / Colour turn-page buttons
case](https://makerworld.com/en/models/3400159-kobo-clara-bw-color-turn-page-buttons-case). Turning
the reader around to hold it in the other hand also flips the remote, which is why the setting
**Bluetooth → Settings → Swap page-turn buttons when screen is inverted** exists.

### Tested device

Only one remote model has been tested, on a Kobo Clara BW:

- **WX02** ring remote (sold as "wxlj-02", three buttons, classic Bluetooth, announces itself with
  Apple's vendor ID `05AC:0220`), for example [this listing](https://www.amazon.co.uk/dp/B0GTVH33JR).
  The next/previous buttons send swipe down/up (`KEY_1002` / `KEY_1001`). The middle button sends a
  tap (`KEY_1000`) and, on its first press after power-on, a power key (`KEY_116`).

To use it: pair and connect the ring from the plugin's Bluetooth menu, open its key bindings, choose
an action such as next page, select "Register button" and press the ring button.
