# Running Glance on someone else's Mac

Glance is signed with a **self-signed certificate**, not an Apple Developer ID,
and it is not notarized. It runs fine; it just takes one extra step the first
time, and macOS words that step alarmingly.

## Requirements

- **macOS 14 or later**
- **Apple Silicon or Intel** — use a universal build (see below); the default
  build is for the machine that made it only
- **A built-in camera.** Glance explicitly picks the built-in webcam and skips
  Continuity Camera, because an iPhone propped at a different angle would
  invalidate the calibration
- **Two or more displays** to be useful at all. One display works, but there is
  nothing to switch between

## Build something shareable

```sh
./bundle.sh release universal zip      # -> build/Glance.zip
```

Without `universal` the binary carries only the building machine's
architecture and will not launch on the other kind.

## First launch

macOS will refuse the app with "cannot be opened because the developer cannot be
verified". That is Gatekeeper reporting the absence of notarization, not a
problem with the app.

1. **Right-click the app → Open**, then **Open** in the dialog. A plain
   double-click will not offer the choice.
2. If that is refused: **System Settings → Privacy & Security**, scroll to the
   message about Glance, click **Open Anyway**.

Only needed once.

## Permissions

Both are requested in use, and neither is required for the app to start.

- **Camera** — prompted on the first *Start Tracking*. Frames are processed
  on-device and never stored or transmitted.
- **Accessibility** — via **Enable Window Focus…** in the menu. Without it
  Glance can bring an application forward but cannot choose between two
  windows of that same application, so a browser open on both displays keeps
  focus on the window you looked away from. Quit and reopen after granting;
  macOS only applies it on a fresh launch.

## Then calibrate

Start Tracking with no calibration and it runs automatically: three targets per
display, two passes, about fifteen seconds per display. Sit the way you normally
work — calibration measured in an unusual posture describes a desk you do not
use.

Calibration is per-desk and named, and Glance identifies displays by vendor,
model and serial, so it recognises which desk you are at and loads the right
profile without being asked.

## What it will and will not do

It moves the cursor to the display you look at and gives that display's
application keyboard focus. It never clicks.

It tracks **head pose, not gaze**. Glancing with your eyes alone produces no
signal, by design. It helps with deliberate attention switches between monitors,
not quick glances.

**⌃⌥⌘G stops it from anywhere**, without needing the pointer.

Everything it stores lives in `~/.Glance`: calibration profiles, remembered
cursor positions and logs. Numbers only, no imagery. Deleting that folder resets
it completely.

## If it misbehaves

`~/.Glance/movement.log` records every move: the target, the resolved
application, the window raised, and which app had focus before and after.
`~/.Glance/calibration.log` records every calibration outcome.
