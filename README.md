# Glance

Native macOS menu-bar utility that moves the cursor to the display you look at,
and gives that display's application keyboard focus.

It exists to stop one specific annoyance: turning to another monitor, typing,
and watching the keystrokes land in the window you just looked away from.

**⌃⌥⌘G stops it from anywhere**, without needing the pointer.

Head pose, not gaze. Glance reads where your head is pointing, via macOS Vision.
Your eyes are never located. Glancing with your eyes alone produces no signal,
by design — it helps with deliberate switches between monitors, not quick looks.

## What it does, and what it refuses

A target held still for the dwell period (400 ms by default) moves the cursor to
that display and activates the application there. It **never synthesizes a
click** — a click lands on whatever pixel is beneath it, inside an application
Glance does not control and cannot undo.

Everything that can refuse, does:

| Guard | Effect |
|---|---|
| `TrackingState.allowsCursorMovement` | exactly one state permits movement |
| calibration validity | a moved or resized display suspends its own mapping |
| confidence + ±2° margin | a yaw near a display boundary is refused |
| dwell | a target must hold still for `dwellMs` |
| no-repeat | never moves twice to the same target |
| hysteresis | leaving a target needs 4° margin *sustained* for a full dwell |
| typing guard | focus never changes within 0.5 s of a keystroke |

The typing guard is asymmetric on purpose: while you are typing the cursor still
moves but focus does not. A stray cursor jump is an annoyance; stealing focus
mid-sentence sends the rest of your keystrokes somewhere else.

## What the measurements decided

Glance was specified as a 3×3 grid of regions per display. It is not one, because
the numbers said otherwise. Four sessions on a two-display desk, each trained on
one pass and scored on a held-out second pass, dwell-averaged over 12 frames
because that is how the app actually decides:

| Discrimination | Result |
|---|---|
| Which display | **99.7–100%** across four sessions |
| Columns within a display | 79–99%, and **not reproducible between sessions** |
| Rows (vertical thirds) | 55–69%, i.e. useless |

**Pitch is not weak, it is harmful.** Including it in the display classifier
dropped accuracy from 99.7% to 89.1%. Mean pitch per target also drifted 2–4°
between passes a minute apart while yaw held to about 1°, and the pitch range
*compressed* on the second pass — people move their heads less and their eyes
more as a task repeats, so the vertical axis degrades with familiarity rather
than settling. The classifier is one-dimensional: yaw only.

**Vertical subdivision is gone.** Rows failed in every session, and a
hierarchical classifier (column by yaw, then row by pitch within that column)
scored 61.1% against 61.8% — not a classifier problem.

**Columns are opt-in and off by default.** The same display measured 97%, 99%
and 79% within one hour. Calibration still measures and reports column
separability, and will enable strips above 95% if you ask for them in Settings,
but a single session's score does not predict the next one.

So the unit of targeting is the display, and within a display position comes
from memory rather than prediction — see below.

**Errors live at the seam.** Every display misclassification came from the
built-in display's edge nearest the external monitor. Refusing samples within
±2° of the boundary removed all of them and cost 8% of samples, which dwell
recovers.

## Cursor memory

The cursor returns to **where you were working on that display**, not to the
display's centre. On a wide monitor the centre is a different window from the
one you were in, so centring would focus the wrong app — the same failure Glance
exists to prevent, relocated inside one monitor.

Two sources feed it, in order of trust:

1. **observed** — where the pointer sat under your own hand. Exact.
2. **inferred** — the centre of the window that was frontmost on that display
   when you looked away. Coarser, but it needs no mouse at all.

The second source matters because Glance moves the pointer itself: on a display
you drive from the keyboard, the pointer's position says nothing about your
intent. Glance never records its own warps, or the memory converges on whatever
fallback it started from. It persists to `~/.Glance/cursor-memory.json`.

This is memory, not prediction, so it has no accuracy to lose.

## Calibration

Start Tracking with no calibration and it runs automatically; otherwise use
**Calibrate Displays…**. Three targets per display, two passes, about fifteen
seconds per display. SPACE or click to begin, ESC to cancel.

Every display goes dark at once, and a single drop travels between them in the
order your displays physically sit — left to right, then back right to left on
the second pass, so it never jumps across the desk. Sit the way you normally
work: calibration measured in an unusual posture describes a desk you do not use.

Two passes, not one, because the profile records a *held-out* score. Scoring the
samples it was fitted on would read near-perfect however bad the signal was.

Calibration judges itself by the same standard the app runs at — dwell-averaged,
not per frame. Scoring single frames once rejected a perfectly good desk at 0.89
and demanded recalibration in a loop.

### Several desks

Calibrate once at each desk and name it. Glance identifies displays by vendor,
model and serial, so it recognises which desk you are at and loads that profile
without being asked.

**Calibration Profile** in the menu lists them, with rename and delete. Pinning
one overrides automatic matching, for what recognition cannot settle: two desks
with identical monitor models. A pinned profile that does not fit the displays
present is reported as a mismatch rather than quietly swapped for one that does.

Profiles live in `~/.Glance/calibrations.json` — numbers only, no imagery. A
display that moves or changes resolution invalidates the mapping built against
it; a *disconnected* display leaves the others valid.

## Build and run

Run this once, before anything else:

```sh
./setup-signing.sh      # asks for your login password
```

macOS keys camera and Accessibility permissions to an app's code signature. An
ad-hoc signature changes whenever the binary changes, so without a stable
identity every rebuild looks like a brand-new app and every permission has to be
granted again. The script creates a local self-signed certificate — no Apple
account, nothing published, removable from Keychain Access.

```sh
swift build
swift test                  # 96 tests
./bundle.sh                 # -> build/Glance.app
./bundle.sh install         # also copies to ~/Applications
open -n build/Glance.app
```

`open -n` matters: plain `open` activates an already-running instance instead of
passing arguments to a new one.

### Diagnostics

```sh
open -n build/Glance.app --args --diagnose 12   # -> ~/.Glance/diagnose-<stamp>.txt
```

Runs the real camera and reports what Vision produced, what each pose classified
as, and — as a **dry run that moves and activates nothing** — what Glance would
have done. It resolves the window under each target without touching it.

```sh
./build/Glance.app/Contents/MacOS/Glance --selftest    # menu wiring, stub engine, no camera
./build/Glance.app/Contents/MacOS/Glance --focustest   # which activation API actually works
./build/Glance.app/Contents/MacOS/Glance --loginitem   # login item round trip, self-restoring
```

`--focustest` exists because the documented API lies. macOS 14 replaced
unilateral activation with cooperative activation, and from a background agent
`NSRunningApplication.activate()` returns `true` while changing nothing. Glance
uses `activate(from: .current, options: [])`. Re-check it on a future macOS with
that flag rather than trusting the docs.

Every move appends to `~/.Glance/movement.log`, including the raised window's
frame — which is what tells two windows of the same application apart.

### Feasibility probe

The probe that produced the numbers above is kept, since the conclusions are
specific to one person and one desk:

```sh
./bundle.sh probe
open -n build/tools/GlanceProbe.app
```

It walks a 3×3 grid on every display, twice, and reports display/column/row
separability separately, a confidence-gate table, and a verdict phrased as a
roadmap decision. `--replay <csv>` re-scores an old capture without recapturing;
`--verify` self-checks the analysis against synthetic data with a known answer.

## Layout

| Path | Contents |
|------|----------|
| `Sources/GlanceCore` | State machine, settings, pose filter, camera + Vision engine, display geometry, calibration, classifier. No AppKit. |
| `Sources/GlanceApp` | Menu-bar shell, calibration UI, diagnostics. |
| `Sources/GlanceProbe` | Feasibility probe. Not part of the shipping app. |
| `Tests/GlanceCoreTests` | 96 tests. |
| `tools/make-icon.swift` | Draws the app icon at every size; the mark is the calibration drop. |
| `bundle.sh` | Assembles and signs the app. |

`TrackingController` is the only thing the UI talks to. The camera pipeline sits
behind `TrackingEngine`: `VisionTrackingEngine` in normal use,
`StubTrackingEngine` under `--selftest` so the self-check never opens a camera.

`PoseFilter` holds hysteresis in both directions, so a blink is not a lost face
and one lucky frame is not a reacquisition. It withholds pose entirely until
reacquisition is stable, so a caller cannot act on a face that is not yet
trusted.

## Permissions

- **Camera** — prompted on the first *Start Tracking*. Frames are processed
  on-device and never stored or transmitted.
- **Accessibility** — *requested, not required*. Needed only to raise the
  specific window under the target. Activating an application cannot choose
  between that application's own windows, so with a browser open on both
  displays the app is already frontmost and focus would stay put. Without the
  permission Glance still activates applications and says in Settings what is
  lost.
- **Screen Recording** — not needed and not requested. It would only be required
  to read window *titles*, which Glance does not do.

Cursor positioning (`CGWarpMouseCursorPosition`), activation
(`activate(from:options:)`) and window bounds/PID (`CGWindowListCopyWindowInfo`)
all work without Accessibility. ⌃⌥⌘G uses Carbon's `RegisterEventHotKey` rather
than an `NSEvent` global monitor for the same reason — a safety control that
depends on a permission you might not have granted is not a safety control.

Requires macOS 14+. No third-party dependencies.

## Limitations

- Head pose only. Eyes are never located.
- Strips are off by default; whole-display targeting is the reliable mode.
- Displays close together, or stacked vertically, are the arrangement head pose
  cannot resolve. Two monitors roughly 40° apart in yaw is what was measured.
- Vision loses the face past roughly ±50° of yaw, so a display far to one side
  becomes unreliable at its far edge. It fails closed: no face, no movement.
- The evidence is one person, one desk, one camera. It justifies the design; it
  does not establish that the numbers hold for anyone else.

Everything Glance stores lives in `~/.Glance`: calibration profiles, remembered
cursor positions and logs. Numbers only, no imagery. Delete the folder to reset.

## License

MIT — see [LICENSE](LICENSE).
