<p align="center">
  <img height="182" src="/assets/app-icon.png">
</p>

<p align="center">
  <img src="/assets/title.svg" alt="Let your agents run with your MacBook lid closed">
</p>

---

A macOS menu bar app that prevents your MacBook from falling asleep when the lid is closed, while letting the display turn off like normal to preserve battery and reduce heat.

Motivated by the need to let coding agents stay running while you carry your MacBook around.

<p>
  <img width="560" height="218" alt="590059860-a03f5bb4-d979-4af5-a895-949414f0efb8" src="https://github.com/user-attachments/assets/e3f5dc98-7fab-4e14-9bcb-6ff621a51d05" />
</p>

## Installation & Usage

Install through the `.dmg` in Releases.

Requires App Background Activity permission (`System Settings -> General -> Login Items & Extensions`). Should pop up automatically on first run.

Left click to open the status window, where you can see why Modafinil is active, inactive, or waiting, and activate/deactivate it. Right click for menu, where you can quit the app and also uninstall it.

Opening Modafinil from Launchpad or Finder shows the same controls in a regular app window, even when the menu bar icon is hidden because the menu bar is full. Closing that window returns Modafinil to its lightweight menu bar mode.

The menu also includes an "Only While Codex Is Running" option. When enabled, Modafinil keeps sleep prevention requested but only applies it while a Codex app or `codex` command is running.

## iPhone companion access

Open Modafinil from Launchpad and choose **Companion Setup…** to pair the iPhone companion app. Modafinil discovers the Mac's Tailscale IPv4 address and current Wi-Fi MAC address, lets you enter the XR wake relay address and up to four comma-separated wake MAC addresses, and creates a private pairing QR code.

The Mac listener is event-driven and listens on TCP port `48765`. It accepts only loopback and Tailscale source addresses. Every request and response is authenticated with a locally generated 256-bit secret; requests also require a current timestamp and a unique UUID to prevent replay. The root helper is never exposed to the network.

A companion sleep request first arms a one-time wake lease, disables Modafinil, and receives an acknowledgement from the signed local helper. The helper then puts the Mac to sleep after a short delay so the network response can finish. When macOS posts its wake notification, Modafinil enables a 90-second provisional wake lease while the iPhone reconnects and confirms **Keep Awake**.

The pairing secret is stored only in the current macOS user's preferences. Generating a new secret invalidates all previous pairings.

For a local signed build, `build/build.sh` keeps the release identity as its default but accepts an override:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build/build.sh
```

The helper derives its own signing team at runtime and accepts only the Modafinil app identifier signed by that same team.

Tested thus far only on Apple Silicon with macOS 13+.
