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

## Sleep timer and confirmed results

Use **Sleep Timer** to choose 1–1440 minutes, update, or cancel. The privileged
helper stores the timer, so UI suspension and helper restarts do not lose it.
Quitting Modafinil cancels scheduled and pending sleep; reboot discards a timer.
Missed timers never put a just-awakened Mac back to sleep.

The helper requests sleep through public `IOPMSleepSystem`, records a durable
receipt, and checks kernel sleep/wake timestamps. Acceptance is not confirmation.
At most three requests run over 32 seconds; any observed sleep ends retries,
even if the Mac wakes immediately afterward. Native errors and missing sleep
transitions are reported in both apps. Continuous time bounds the timer and
verification window despite wall-clock changes. The journal is root-written
at `/Library/Application Support/Modafinil/sleep-journal.json`; it contains only
timer/result metadata, with no pairing keys, credentials, or screen contents.

The iPhone clears expired countdowns, refreshes on foreground entry and performs
one delayed result check. It labels an unreachable Mac as unverified. The Mac
continues to permit network wake and macOS maintenance; this is not a guarantee
of uninterrupted deep sleep. Companion 1.4 uses protocol v3; v1/v2 clients remain
compatible but cannot display sleep receipts.

Validation on 2026-09-29 included 40 passing Swift tests, a signed release build,
Mac timer save/cancel checks, and an approved live one-minute timer. macOS logged
software sleep from the helper at 21:14:51 CEST; the durable receipt confirmed
kernel sleep at 21:14:53 after one native request. Connecting USB-C caused a wake
at 21:16:13. macOS returned to sleep and fully woke at 21:17. Keep-awake was
restored and both test timers were cleared. Because power was connected during
sleep, this validates the sleep path and recovery but is not an isolated proof
of the scheduled wake source.

## Companion wake recovery (Mac 0.4.1 / Companion 1.5)

Protocol v4 signs the Mac's current private Wi-Fi and hardware wake addresses.
The phone refreshes its existing Keychain pairing from verified responses; it
preserves both secrets and all endpoints. The Mac prefers live addresses over
stale saved targets, retaining configured extra interfaces up to four total.
Install Mac 0.4.1 before Companion 1.5. Existing v1/v2/v3 phones and the iPad's
v1 relay retain their original protocol and response signatures.

The phone allows 60 seconds for network recovery and sends at most four signed
relay wake requests during that foreground attempt. Sleep timers now arm remote
recovery, and maintenance wakes retain the authorization until Keep Awake or an
explicit local change, cancellation or quit. Each wake still receives only the
existing 90-second provisional keep-awake lease, which can temporarily extend
background awake time. There is no new idle polling or permanent keep-awake.

Mac 0.4.1 also ignores already-fired records retained by macOS when replacing
or cancelling future wake alarms. Attempting to cancel such an expired record
returns IOKit Not Found and previously rolled back a valid replacement alarm.
Active Modafinil alarms and other apps' events remain protected.

Validation on 2026-10-07: 46 Mac Swift tests passed, the signed build was installed,
and a native one-minute timer produced kernel-confirmed sleep at 12:21:26 and a
later wake at 12:21:55 with recovery authorization retained. Provisional keep-awake
expired as intended. The wake was not isolated magic-packet proof. The paired
Companion build passes 29 tests, including late reconnect and signed address
updates. Installing the new Signulous IPA and a physical cellular/closed-lid AC
cycle remain user acceptance. Investigation and artifact recovery are recorded
in the companion repository's `docs/wake-recovery-2026-10-07.md`.

## Wake timer

Use **Wake Timer** in the Mac window or menu bar popover to pick a one-time
date and time, then click **Schedule Wake**. **Update Wake** replaces that alarm;
**Cancel Wake** removes it. Modafinil Companion 1.3 on iPhone controls the same
alarm with **Wake At…** and **Cancel Wake Timer**. Refresh the phone to see
changes made on the Mac.

The privileged helper uses `IOPMSchedulePowerEvent` to register a native wake
event, between one minute and 30 days ahead, owned by
`com.narcotic.modafinil.scheduled-wake`. Updates and cancellation preserve
other apps' power events. The alarm survives sleep and app restarts and needs
no iPhone or iPad connection once saved. Keep the Mac on AC and Modafinil open
to enable keep-awake after the alarm. The timer wakes from sleep; it does not
schedule shutdown/power-on, unlock the Mac, or launch a task itself.

Quitting the app leaves the wake alarm in macOS. Cancel it explicitly before
quitting if you do not want it. The app restores the pending alarm on launch;
alarms missed by more than five minutes do not unexpectedly enable keep-awake
when the app is reopened later. The sleep timer remains separate.

Companion protocol v2 authenticates the scheduled wake timestamp. The Mac still
serves v1 clients using their original response format; the existing jailbroken
wake relay and pairing secrets are unchanged.

## iPhone companion access

Open Modafinil from Launchpad and choose **Companion Setup…** to pair the iPhone companion app. Modafinil discovers the Mac's Tailscale IPv4 address and current Wi-Fi MAC address, lets you enter the XR wake relay address and up to four comma-separated wake MAC addresses, and creates a private pairing QR code.

The Mac listener is event-driven and listens on TCP port `48765`. It accepts only loopback and Tailscale source addresses. Every request and response is authenticated with a locally generated 256-bit secret; requests also require a current timestamp and a unique UUID to prevent replay. The root helper is never exposed to the network.

A companion sleep request first arms a one-time wake lease, disables Modafinil, and receives an acknowledgement from the signed local helper. After a short delay for the response, the helper requests sleep and records whether the kernel confirms it. When macOS posts its wake notification, Modafinil enables a 90-second provisional wake lease while the iPhone reconnects and confirms **Keep Awake**.

The pairing secret is stored only in the current macOS user's preferences. Generating a new secret invalidates all previous pairings.

For a local signed build, `build/build.sh` keeps the release identity as its default but accepts an override:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build/build.sh
```

The helper derives its own signing team at runtime and accepts only the Modafinil app identifier signed by that same team.

Tested thus far only on Apple Silicon with macOS 13+.
