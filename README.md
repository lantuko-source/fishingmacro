# Fishing Macro for macOS

Version 0.2.0 is a native Mac app for Grand Piece Online fishing. **Start fishing** captures the screen automatically, locates water, sends a cast click, waits for the fishing bars, and holds/releases to balance the black box on the white target. It repeats until you press **P** or **Stop fishing**.

The app has no session duration or catch limit. Ordinary clicks and small window movements do not stop it. The water point is cached relative to the Roblox window and follows its movement; it is not selected again for every cast.

**Live game status:** the previous build failed to cast in user testing. This version replaces process-directed mouse events with standard macOS mouse-stream events, including movement before the press and a 120 ms press/release for casting. The actual rod throw and full reeling cycle still need user confirmation in Roblox. Automated checks do not establish game input acceptance.

## Install and use

Requires macOS 14 or newer; the ZIP contains a universal Apple silicon/Intel app.

1. Quit the old Fishing Macro, unzip `FishingMacro.zip`, and replace **Applications → Fishing Macro.app**.
2. Allow **Screen Recording** and **Accessibility** if macOS requests them. Use the installed Applications copy.
3. In GPO, equip your fishing rod and bait, face open blue water, and close in-game menus.
4. Press **Start fishing**. Capture and setup happen automatically; after a three-second countdown it sends the first cast click. There is no separate capture button or preview switch.
5. Press **P** to stop from any app, or use Stop fishing/the menu bar. P is registered only during an active run, so it is released for ordinary typing afterward.

The Mac is kept awake against idle system/display sleep during an active run; that activity is released on Stop or Quit. Manual sleep, closing the lid, screen locking, or a Roblox disconnect can still interrupt operation. The app does not bypass those states or reconnect to the game.

## Loop and recovery

- **Start:** capture the display containing Roblox and find a mostly blue water patch inside its visible window. Prefer nearby water rather than blue sky. Save that position relative to the game window.
- **Cast:** send a mouse-move event to the saved point, then normal left-button down/up through the macOS HID event stream. The press lasts approximately 120 ms. The UI counts a cast as **sent**, not as proof Roblox accepted it.
- **Wait:** look for the blue lane, black box, white target, and green gauge. After two tracked frames, enter reeling. If no bite is detected for 45 seconds, retry a cast without ending the run.
- **Reel:** hold when the box is below the white line; release when it is above. Recent error velocity helps reduce overshoot. Individual holds are bounded and briefly released without ending the session.
- **Finish:** full green-gauge evidence followed by a closed minigame counts as a confirmed catch. Cast again after 1.5 seconds.
- **Recover:** if markers become ambiguous, release and look for the bars again. If the minigame disappears after a lost or unconfirmed attempt, retry after a short delay. Only confirmed full-gauge transitions increase the catch counter.
- **Window movement:** update the saved point and reacquire tracking automatically. Normal clicks do not stop the macro; their release is reconciled with the next controller frame. The app will move back to the saved water point when it sends its next press.
- **Switching apps:** release and pause while Roblox is not in front, then resume when it returns. This keeps the run active without sending new clicks into other apps.
- **Stop:** P, Stop, or Quit releases the held mouse button and unregisters P. Actual capture errors or missing permissions stop with a message. A crash can prevent normal cleanup; physically click/release once if a button is stuck.

The visual detector was checked against the supplied screenshot and simulated targets. Other rods, UI scales, lighting, messages, inventory screens, and updated game layouts may need further tuning. It cannot identify every menu or disconnect screen. It uses ordinary input only, with no Roblox injection, memory access, anti-cheat bypass, auto-selling, login handling, or reconnect loop.

## Permissions and signing

The local build uses the Mac's unique available Apple Development or Developer ID certificate for a stable signing identity. Set `FISHING_SIGN_IDENTITY` when multiple identities exist. Neither certificates nor private keys are added to the repository. Builds without a unique signing identity, including CI, fall back to ad-hoc signing and warn that an update may require permission approval again. Builds are not notarized; Developer ID signing/notarization is needed for smooth public distribution.

Earlier ad-hoc builds could leave a permission entry switched on while macOS refused access to the new executable. If that happens, quit the app, remove only Fishing Macro's old entry from the relevant privacy settings, and add the Applications copy again. Never reset all apps' permissions for this issue. Successful ScreenCaptureKit image capture is accepted as stronger evidence than an inaccurate preflight result; actual capture errors still stop input.

## Privacy

Initial setup and minigame discovery capture the display containing Roblox; other visible apps may be present in memory. This app's windows are excluded. Visual decisions are restricted to Roblox's visible bounds, and new input requires Roblox in front. After the bars are found, capture is cropped to their region. Images stay in memory and are not saved or uploaded. The app makes no network requests.

## Build and checks

Apple Command Line Tools or Xcode are required. No third-party packages are installed.

```sh
bash scripts/check.sh
bash scripts/build-app.sh
```

The output is `dist/FishingMacro.zip`; extract the app into Applications. The build does not leave a duplicate app in the synced development folder. A universal build compiles both Apple silicon and Intel binaries. `bash scripts/build-app.sh --debug` creates a quicker local build for the current Mac.

The scripts use SwiftPM's native build engine to work with Command Line Tools installations lacking Xcode's full macro plugins. Newer Swift releases can emit a deprecation warning for this build-engine option. Checks use a standalone executable so full Xcode/XCTest is not required.

Checks cover casting before the minigame exists, mouse move/down/up event construction through an injected sink, unlimited runtime, more than ten catches, manual-click continuation, pause/resume, geometry changes, retries, and stop cleanup. They also cover water detection, bar tracking, momentum control, green fill, and catch confirmation. No real mouse events are posted by the checks. The optional reference-image check additionally verifies automatic discovery and approximately 22% progress in the supplied 650 × 864 screenshot:

```sh
FISHING_SAMPLE=/absolute/path/to/the/reference.png bash scripts/check.sh
```

That image remains outside the repository. With it, 28 checks passed during development; without it, the optional screenshot check is skipped. **Fishing → Open test image** allows offline inspection; it cannot enable live input.

## Policies

The user confirmed GPO permits macros; that permission was not independently verified from a current official rule. [Roblox prohibits cheating and exploiting](https://en.help.roblox.com/hc/en-us/articles/203312450-Cheating-and-Exploiting), and that page does not explicitly authorize fishing macros. This app uses ScreenCaptureKit and standard macOS mouse events. It contains no anti-cheat bypass or credential handling.
