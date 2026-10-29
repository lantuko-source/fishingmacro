# Fishing Macro for macOS

A native Mac app for supervised Grand Piece Online fishing. **One screen capture is the entire setup.** Face the ocean, capture the screen, and start. The fishing bars do not need to be visible during setup.

The app finds a clear blue water patch inside Roblox, clicks to cast, waits for the fishing UI, detects the blue lane/black box/white target/green gauge, and balances by holding to rise and releasing to fall. A confirmed catch allows the next cast.

**Status: native app builds and automated vision/controller checks pass. Live Roblox input acceptance, timing, and complete catch/recast cycles still need in-game testing.**

## Install

Requires macOS 14 or newer. The release ZIP contains a universal app for Apple silicon and Intel.

1. Unzip `FishingMacro.zip`, move **Fishing Macro.app** to Applications, and open it.
2. Enable **Screen Recording** and **Accessibility** using the sidebar. If macOS requires a restart after granting Screen Recording, quit and reopen the app. Refresh permission status after enabling Accessibility.
3. Open the official Roblox Player, join GPO, equip your rod/bait, and face open blue water. Keep the game window fully on one screen, with chat and inventory closed.
4. Click **Capture entire screen**. The app briefly brings Roblox forward, captures its screen, and returns to show the captured view. It automatically selects the screen containing Roblox. No separate bar selections, point selections, or screenshots of an active minigame are required.
5. The green crosshair marks the water location it found. Start in **Preview — no clicks** to watch detection while you fish manually. Preview generates no mouse input.
6. Stop preview, switch **Preview — no clicks** off, and press **Start fishing**. Roblox comes forward, a three-second countdown completes, and the app finds water in a fresh frame before clicking.

Use **Control + Option + X** or the menu bar Stop command at any time. The app starts stopped and in preview on every launch. Keep it supervised.

Local builds use an available Apple Development or Developer ID certificate when there is exactly one valid signing identity on the Mac. This gives successive builds a stable signing requirement. Set `FISHING_SIGN_IDENTITY` to explicitly choose an identity when needed. No certificate or private key is copied into the repository. If no unique identity is available, the build uses an ad-hoc signature and warns that replacing the build can require permission approval again. CI builds without a configured identity use this fallback.

Builds are not notarized. A downloaded build may require macOS's normal **Privacy & Security → Open Anyway** flow. The app does not disable Gatekeeper. Developer ID signing and notarization are needed for smoother public distribution.

### Permission enabled in Settings, but the app still asks

Version 0.1.0 used changing ad-hoc signing requirements. An older grant can remain switched on in Settings while macOS refuses access to the current executable. A duplicate app in a synced build folder was also found during troubleshooting; that copy failed signature validation because of Finder metadata.

Version 0.1.1 keeps only the ZIP in the build folder, uses the available stable signing identity for this local installation, keeps a Settings button available, and accepts a successful ScreenCaptureKit image as proof even if the legacy preflight check reports false. It still stops when actual capture fails. Moving from the old signature to the certificate-backed build requires one clean permission grant:

1. Quit Fishing Macro.
2. In **Screen & System Audio Recording** and the app's **Accessibility** settings, remove the old Fishing Macro entry and add **Applications → Fishing Macro.app** again. Approve only the permissions you intend the app to have.
3. Reopen the Applications copy. Click **Capture entire screen** to verify capture. Do not reuse an old Dock shortcut pointing into the development folder.

Only Fishing Macro's old grants may need resetting; there is no reason to reset all apps' privacy settings.

## Automatic loop

- **Find water:** inspect blue patches inside the selected Roblox window, excluding window edges and the lower hotbar area. Require a large, mostly blue neighborhood rather than clicking an arbitrary blue pixel. If no candidate is clear, stop without clicking.
- **Cast:** move the pointer to the detected ocean point and click once for about 80 ms.
- **Wait for bite:** watch the full screen for the fishing UI. This can take up to 35 seconds; a timeout stops rather than repeatedly recasting.
- **Find the bars:** locate a narrow light-blue lane with dark side rails, the black movable box, a thin white target, and a tall green gauge to its right. Require three tracked frames before reeling. No bars during the waiting period is expected.
- **Balance:** black box below target → hold to rise. Above target → release to fall. Error velocity is used to reduce overshoot. Once acquired, only the small gauge area needs to be captured for faster tracking.
- **Confirm:** require at least three tracked frames with a gauge at 97% or higher, then at least 0.4 seconds without the blue lane within two seconds. Wait another 1.5 seconds, find water again, and recast.

The first detector is tuned to the layout and colors shown in the supplied screenshot. It has not been validated against every rod, lighting condition, UI scale, notification, or game update. It stops when the layout is ambiguous. A minigame that closes too quickly to show the required full-gauge evidence will stop the loop; a short recording of that transition would be needed to refine confirmation.

## Stop controls and limits

- **Control + Option + X** is registered globally. The app's menu bar also has Stop and Quit controls.
- Escape, Return, slash, and Tab stop a session when keyboard monitoring has permission.
- During live input, moving the pointer more than 24 screen points from the cast point or physically clicking stops the run. Manual clicking is allowed in preview.
- Losing Roblox focus, changing/moving/resizing/closing its selected window, display sleep, Secure Input, or lost Accessibility permission stops the session.
- Any missing or ambiguous marker releases immediately; 0.8 seconds without reliable reeling stops the session.
- Capture errors stop immediately. Capture/analysis deadlines and a 0.6-second frame watchdog prevent continuing on stale visual information, subject to macOS scheduling.
- Holds are limited to 1.5 seconds followed by a short release. Default session duration is 120 seconds, selectable from 30–300 seconds. Every session stops at 10 confirmed catches.
- Normal Stop, close, and Quit paths release a held button to the original Roblox process. A crash or revoked permission can prevent release; physically click/release in Roblox once if needed.

The app cannot reliably identify every in-game menu, disconnect prompt, moderator message, or Roblox experience. Keep GPO in front with menus closed, supervise the run, and stop before interacting. If Roblox ignores ordinary synthetic mouse input, stop and investigate. There is no bypass fallback, auto-idle, reconnect loop, auto-selling, game injection, memory access, modified-client support, or credential handling.

## Privacy

Screen Recording captures the **entire display containing Roblox** during initial capture and while finding water/the minigame. Other visible apps on that display may therefore be present in memory. This app's own windows are excluded. Visual decisions and clicks are restricted to the known Roblox window. Reeling captures are cropped to the discovered gauges. Captured images stay in memory and are not saved or uploaded. The app makes no network requests.

## Build and checks

Apple Command Line Tools or Xcode are required. No third-party packages are installed.

```sh
bash scripts/check.sh
bash scripts/build-app.sh
```

The output is `dist/FishingMacro.zip`; extract the app into Applications. The build does not leave a duplicate app in the synced development folder. A universal build compiles both Apple silicon and Intel binaries. `bash scripts/build-app.sh --debug` creates a quicker local build for the current Mac.

The scripts use SwiftPM's native build engine to work with Command Line Tools installations lacking Xcode's full macro plugins. Newer Swift releases can emit a deprecation warning for this build-engine option. Checks use a standalone executable so full Xcode/XCTest is not required.

Checks cover water without fishing UI, absence of a safe water candidate, bar detection, the white line over the black box, cropped coordinates, hold/release direction, momentum control, ambiguous/missing markers, green fill, and catch confirmation. The optional reference-image check additionally verifies automatic discovery and approximately 22% progress in the supplied 650 × 864 screenshot:

```sh
FISHING_SAMPLE=/absolute/path/to/the/reference.png bash scripts/check.sh
```

That image remains outside the repository. With it, 19 checks passed during development; without it, the optional screenshot check is skipped. **Fishing → Open test image** allows offline inspection; it cannot enable live input.

## Policies

The user confirmed GPO permits macros; that permission was not independently verified from a current official rule. [Roblox prohibits cheating and exploiting](https://en.help.roblox.com/hc/en-us/articles/203312450-Cheating-and-Exploiting), and that page does not explicitly authorize fishing macros. This app uses ScreenCaptureKit and normal macOS mouse events. It contains no anti-cheat bypass or credential handling.
