# ANSWER — Round 2: the mapping, the hands, the corners

Fable, 2026-08-08. Headline verdicts first, because two of them dissolve the
hardest tensions in your document:

1. **SDL holding a GCController does NOT block `ar_accessory_load_from_device`.**
   Input and accessory loading are orthogonal; your "single most important
   question" has the good answer.
2. **The aggregate MFi device is GONE once SpatialGamepad is declared — and
   your own 1.1.2.22 run already proves it.** You filtered only
   spatial-category devices out of SDL and SDL's list came up EMPTY. If an
   aggregate still existed, SDL would have kept it. So "SDL keeps driving the
   aggregate unchanged" is dead; pick the architecture in Q1.4 below.
3. The exact element names are confirmed from the local XROS 26.5 SDK — no more
   guessing.
4. Stop reading the Settings row as an instrument. And for the corners: don't
   theorize, **bisect with the OTA hub** — zero new builds needed.

---

## Q1 — The input mapping

### 1. Element names (verified in `GCInputNames.h`, XROS 26.5 SDK)

All of these are real exported constants, availability visionOS 26.0:

| Control | Constant | Type / where it lives |
|---|---|---|
| Thumbstick | `GCInputThumbstick` (GCInputNames.h:60) | `GCInputDirectionPadName` — a DIRECTION PAD, which is exactly why LiveInput shows it under `dpads`, not `axes` |
| Thumbstick click | `GCInputThumbstickButton` (:64) | button |
| Face A (Cross/Square) | `GCInputButtonA` | button |
| Face B (Circle/Triangle) | `GCInputButtonB` | button |
| Grip (L1/R1) | `GCInputGripButton` (:72) | button |
| Trigger (L2/R2) | `GCInputTrigger` (:88) | button — **singular**, not Left/RightTrigger; each hand device has one |
| Menu (Menu/Create) | `GCInputButtonMenu` (:126) | button |

PS button is system-reserved. Analog trigger value via `pressedInput.value` on
the button element; capacitive-touch events had a system bug fixed in visionOS
26.3. Same `GCInput*` names appear under `GCPhysicalInputProfile` (with the
thumbstick under `axes` there — the LiveInput/`dpads` quirk is the documented
difference).

**Write the mapping against the constants, but add a name-agnostic fallback**
so a naming surprise degrades instead of dying: thumbstick = the first
`GCControllerDirectionPad` among `dpads`; trigger/grip = the button element
whose name contains "Trigger"/"Grip"; A/B by constant. Log every element name
the inventory sees (see Instruments below) — one build converts all remaining
uncertainty into facts.

### 2. Chirality before ARKit answers

There is **no chirality API anywhere in GameController** — I grepped the whole
framework's headers; nothing matches chiral/handed. Your options, in order:

- **Heuristic, synchronous:** the device's `vendorName`/product string. Sony
  ships distinct left/right units, and the pairing UI names them individually —
  log the string in the inventory; it almost certainly carries the hand. Until
  verified, treat as heuristic.
- **Authoritative, and earlier than you think:**
  `ar_accessory_get_inherent_chirality()` on the `ar_accessory_t` — available at
  **load completion**, well before any provider runs or anchors flow
  (accessory_tracking.h:141-147). So the unknown-chirality window is connect →
  load-complete, typically well under a second.
- Design for the window: bind controllers to hands lazily. Until chirality is
  known, either merge both sticks into movement (harmless for a moment) or hold
  neutral. Never guess-and-stick.

(`ar_accessory_anchor_get_held_chirality` also exists on anchors — that's which
hand it's *currently held in*; inherent is which hand it's *for*. Use inherent
for the layout.)

### 3. Aggregate persistence — answered by your own data

Gone, per the 1.1.2.22 empty-SDL observation above. The inventory build will
confirm, but plan on: declaration present ⇒ two
`GCProductCategorySpatialController` devices, no aggregate.

### 4. Architecture decision + the presence problem

**Decision: the native fixed-layout backend owns the spatial pair (charter
A10), with spatial-category devices filtered out of SDL.** The 1.1.2.22 failure
was not this architecture — it was guessed element names shipped in the same
build that removed the working path. Do not re-litigate the architecture over
that; fix the process (below).

Why not "leave input on SDL's generic branch" (your 1.1.2.23 state): SDL's
`product=4` generic branch will open each half as a raw joystick with elements
auto-mapped in alphabetical order, no SDL_GameController mapping for that GUID,
no chirality, and coopdx's bind/mapping machinery pointed at two half-pads. Even
if it half-works it is fragile, wrong-handed at random, and exactly the
"inherited flat-screen binds scramble VR controllers" trap the donor's ledger
paid for. It also can't distinguish left-stick-moves from right-stick-camera.

**The presence problem** (touchscreen overlay appearing): least-invasive fix is
SDL's own virtual-joystick API — `SDL_JoystickAttachVirtual` exists in SDL 2.32.
When ≥1 spatial controller is connected, attach ONE virtual gamepad (with a
mapping string so coopdx's SDL_GameController path recognizes it), detach when
the count hits 0. Leave its reported inputs neutral and keep writing the pad
from `controller_vision` — presence via SDL, input via the fixed layout, vendor
untouched. Before building: grep coopdx for the actual touch-overlay predicate
(SDL joystick count vs opened-gamecontroller count) and satisfy the one it uses.

**Process rule for the next build (respecting Austin's rationing):** ship BOTH
input paths behind a runtime toggle — a settings row or env var selecting
"SDL generic" vs "native fixed layout", default SDL. One build then carries the
inventory log, the real-name mapping, and an instant fallback if the mapping
misbehaves. Never again couple "remove working path" and "enable unproven path"
without a switch.

---

## Q2 — Hands

### 1. Does SDL's open block the load? NO — and this unblocks everything

GameController has no exclusive-open concept. SDL merely holds the same
`GCController` object and reads profiles/handlers; `ar_accessory_load_from_device`
registers that same object with the system accessory registry. Input reading
and accessory loading/tracking are designed to coexist — Apple's WWDC25 session
289 demonstrates handling controller buttons *and* spatial tracking together,
and ALVR (forums thread 804722) polls both Sense controllers via
GCControllerLiveInput while tracking them, in one process. **"SDL keeps input,
ARKit supplies only poses" is a supported configuration.** The two goals are
not in conflict — which also means the Q1 architecture choice is purely about
input quality, not about unblocking hands.

### 2. Remaining failure modes for the load, ranked

a. **Loading the wrong object and misreading the log.** `vr_adopt()` loads
   every controller; a leftover non-trackable device (a real gamepad, or a
   stale aggregate pre-reboot) fails with 1200 *correctly*. Log per-device
   (name + category + result) so one expected failure can't masquerade as THE
   failure.
b. **Double-load of the same device** (queued load + a second `didConnect`,
   e.g. on focus changes). Dedupe by device identity before calling.
c. **Focus/foreground gating.** "Only the currently focused and authorized app
   can track accessory movements" (WWDC). The prompt path you have is fine;
   if a load issued while backgrounded/unfocused fails, retry on foreground
   and once more on immersive-space entry. Cheap insurance: retry a failed
   load exactly once, 2s later, and log both results.
d. **Low Power Mode** on the headset degrades/stops spatial accessory tracking
   (forums thread lists it). Have Austin check Settings > Battery before the
   run. This one produces "loads OK, anchors never track" more than load
   failure, but rule it out.
e. **The key never reached the built product.** Verify once from inside the
   app: log `[[NSBundle mainBundle] objectForInfoDictionaryKey:@"GCSupportedGameControllers"]`
   at boot. One line, closes the "did the build carry it" doubt forever —
   remember the plist passes through CMake/Xcode processing.
f. OS tail: be on current 26.x (26.3 fixed spatial-controller input bugs).

### 3. Two-session split — still fine

Unchanged by the enumeration change; the load is session-independent.
Consolidate onto the world-tracking session ONLY if loads succeed and anchors
still don't flow.

### 4. Ordering — load first, provider second, anchors need the space

Apple's canonical sequence: **load accessories → build the accessory-tracking
configuration/provider FROM the loaded set → run on a session**. So:
- The load needs NO provider, NO immersive space. Load eagerly at connect.
- Anchors need: provider running + the app focused — in practice, your
  immersive space open. Expect zero anchors while sitting in the 2D window;
  that is not a failure.
- If an accessory loads *after* the provider is running, safest is to
  recreate the provider with the full set (re-run on space entry anyway).

### The Settings row: withdraw it as an instrument

My round-1 prediction that a row would appear was inference; you've now got a
granted authorization + declared capability and still no row. Treat the row as
undocumented UI that may simply not exist for accessory tracking on this OS
version. The instruments are: the per-device load results + error codes, and
the live anchor count. Nothing else.

---

## Q3 — The square corners

Your audit is good and I found no smoking gun either (I diffed the plist, App
scenes, and host against main: the R0 spike spaces, the two plist keys, spike
scaffolding — nothing that touches window chrome at launch). Two mechanisms fit
"rounded for ~0.5 s, square once Metal presents":

- The adopted scene-less **SDL `UIWindow`** compositing without the system's
  corner treatment once it has real content — a second raw window in the scene
  is exactly the kind of thing the glass mask doesn't automatically cover.
  (But note: the adoption machinery predates the VR phase, so if this is it,
  something *environmental* changed its behavior, not our code.)
- **It isn't our regression at all** — visionOS 26.x changed chrome behavior
  under us during the phase. "The public 1.1.2 doesn't have it" needs
  re-verifying **on today's OS**, not from memory.

**Don't build anything to diagnose this. Bisect with the OTA hub.** Every
1.1.2.N dev build is still installable from `http://goomba/ota`. Have Austin:
1. Install public 1.1.2 on the current OS — corners rounded? If SQUARE, it's
   the OS, not us: file feedback, stop.
2. If rounded: binary-search the 1.1.2.N ladder (~4-5 installs) to the first N
   with square corners. The commit range for one N is small; the diff will name
   the change, and we take it from there.
Minutes of installing, zero speculative builds, definitive. If the bisection
lands somewhere surprising, complement with a layer dump over the console
bridge you just armed: at t≈0.3 s and t≈2 s, print every `UIWindow` (class,
frame, level) and its layer's `mask`/`cornerRadius`/`masksToBounds`; diff the
two snapshots — it will literally name the layer that covers the corners.

---

## Instrument review (you asked)

Your three instruments are right. Add four cheap lines to the same build:
1. Per-controller `vendorName`/product string (chirality heuristic + aggregate
   identification).
2. The full element-name list per controller (`physicalInputProfile.elements.allKeys`
   and LiveInput's `buttons`/`dpads` keys) — these ARE the mapping deliverable.
3. The `GCSupportedGameControllers` value as read from the main bundle (2e).
4. Per-device load result lines keyed by device name, not just a count (2a).

And the one process change: both input paths in the build, runtime-switchable,
default to the currently-working one. Then a bad experiment costs a toggle, not
a device round.
