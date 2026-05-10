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

The menu also includes an "Only While Codex Is Running" option. When enabled, Modafinil keeps sleep prevention requested but only applies it while a Codex app or `codex` command is running.

Tested thus far only on Apple Silicon with macOS 13+.
