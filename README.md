<p align="center">
<img height="182" src="/assets/app-icon.png">
</p>

<p align="center">
<img src="/assets/title.svg" alt="Let your agents run with your MacBook lid closed">

---

Modafinil is a macOS status bar app for one specific workflow:

1. Prevent lid-close sleep with `pmset -a disablesleep 1`.
2. Immediately turn off the built-in display when the lid closes without an external display connected.
3. Restore normal lid-close sleep behavior when turned off.

It exists because the existing utilities checked did not combine lid-close sleep prevention with immediate display turn-off on lid close.

## Architecture

Modafinil is split into two compiled processes:

- `Modafinil.app`: user-session status bar app. It owns the lid-close listener and runs `pmset displaysleepnow` when the lid closes while Modafinil is active, unless an external display is connected.
- `ModafinilHelper`: privileged LaunchDaemon. It exposes a narrow XPC API for only:
  - `pmset -a disablesleep 1`
  - `pmset -a disablesleep 0`
  - reading the current `SleepDisabled` state

The helper is bundled inside the app and registered with `SMAppService`. The user approves the helper once; after that, turning Modafinil on/off should not require entering an admin password each time.

## Run

Modafinil must run from `/Applications`. If launched from anywhere else, it exits after showing an alert.

Controls:

- Left-click the status bar icon to toggle Modafinil on/off.
- Right-click or Option-click the icon to open the menu.
- If the helper is not installed, turning Modafinil on starts helper setup.
- If macOS reports that approval is required, Modafinil opens App Background Activity settings so the helper can be approved.
- Use **Uninstall Modafinil...** to restore normal sleep behavior, remove the helper, clear Modafinil settings, and quit. The app bundle is deleted only when running from `/Applications`.

Status icon:

- Open eye symbol: sleep prevention is active.
- Half-closed eye symbol: normal sleep behavior is active.
