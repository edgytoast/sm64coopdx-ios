# ANSWER — Round 3: the square corners

Fable, 2026-08-09.

## Q1 — Yes, your mechanism is right, and the symptom itself proves it

Reason it through from the observation: if visionOS applied the rounded-corner
mask to the *composited scene output* (all windows flattened, then masked),
then opaque content in the corners could never square them — the mask would
clip the SDL window's corners exactly as it clips the primary's. The only way
"rounded until the second window paints, square after" can happen is if the
corner treatment is applied **per-window, to windows the system manages** — and
an app-created, scene-adopted secondary `UIWindow` is not one of those. Your
mechanism isn't merely plausible; it is the only mechanism consistent with the
observation.

So: the SwiftUI-owned primary window carries the system chrome; SDL's adopted
window, stretched to full scene bounds with an opaque `CAMetalLayer`, paints
square over the rounded region. Nothing you did wrong — this is the cost of the
two-window graft, and it was always latent in it.

### The timeline contradiction

Two candidate resolutions, and the **outstanding OTA bisect decides between
them at zero build cost** — but note that *the fix is identical either way*, so
do not block the fix on the bisect:

- Austin's memory of 1.1.1/1.1.2 is off (the squaring is subtle; nobody was
  looking at corners then), or
- a visionOS 26.x point update during the VR phase moved/changed the chrome
  behavior for secondary windows (Apple reworks window chrome regularly; a
  scene-composited mask in an earlier build would have hidden this bug, and a
  move to per-window masking would have exposed it — with zero change on our
  side).

Run the ladder when convenient: public 1.1.2 on today's OS first. If it's
square too → OS behavior change, our code was never the trigger, and the fix
below is still the right response. Knowing which world we're in only tells us
whether to expect Apple to move it again.

## Q2 — The fix: copy the primary window's corner treatment, live-tuned once

**Ruling: candidate 1** (apply the radius to the SDL window's layer), with one
critical improvement — don't hardcode the radius, **read it off the primary
window at runtime**:

1. In `SM64_TrackSDLWindowToScene()` (it already runs every frame on the main
   thread and is the natural home), find the primary window: the scene's other
   window (`scene.windows`, the one that isn't `win` — in practice the
   SwiftUI-owned key window).
2. Read `primary.layer.cornerRadius` and `primary.layer.cornerCurve`. If the
   radius is nonzero, mirror all three onto the SDL window:
   `win.layer.cornerRadius = r; win.layer.cornerCurve = same;`
   `win.layer.masksToBounds = YES;`. Re-assert alongside the frame tracking
   (assign only on change, like the frame) — that automatically handles user
   resizes, including the case where the system varies the radius with window
   size.
3. If the primary reads radius 0 (i.e., the system rounds via a mechanism
   invisible to the process — a private mask layer or out-of-process
   compositing), fall back to a hardcoded radius — but don't guess it across
   device rounds: **make the radius settable at runtime through the console
   bridge**, tune it visually against a neighboring system window in ONE
   session, then hardcode the tuned value with
   `kCACornerCurveContinuous`. One round, done.

Do steps 1-3 as one build that also logs, at t≈2 s, for every window in the
scene: class, frame, windowLevel, `layer.cornerRadius`, `layer.cornerCurve`,
`layer.masksToBounds`, and whether `layer.mask` is non-nil. That single log
confirms the mechanism, tells you which branch (2 vs 3) is live, and if it's
branch 2 the fix is already working by the time you read it.

Cost note: `masksToBounds` with a corner radius on a Metal-backed tree costs a
little compositing work; the system pays exactly this for every rounded window
it draws. Not a concern.

**Candidate 2 (host SDL's view inside the SwiftUI hierarchy):** right
architecture, wrong week. It genuinely removes the whole class of problem
(one window, system masking applies), but it renegotiates SDL's window
ownership — the same territory as the load-bearing boot graft — for a cosmetic
defect, days before a release. Put it on the post-1.2.0 list as the durable
simplification, tackled when there's appetite for a device-testing cycle.

**Candidate 3 (inset the frame):** rejected, your instinct is correct — trades
a corner defect for a visible border defect.

## Q3 — Yes, the tracker is legitimate; keep it

A window created before scene adoption, with an explicit frame, is outside
UIKit's automatic scene-relayout path — SDL 2.32 predates scenes and there is
no scene-correct hook you can own here (the scene's delegate belongs to
SwiftUI). Your per-frame compare-and-assign is the honest SDL2 equivalent of
the geometry tracking SDL3 gets natively, it's cheap (assign only on change),
and it is precisely where the corner treatment now also gets asserted. Don't
redesign it. `scene.coordinateSpace.bounds` is a fine source; there's no better
public one for this arrangement.

## Q4 — The unmovable window

Almost certainly system-side: the grab bar and move/resize affordances are
shell chrome rendered and hit-tested *outside* your process — your windows
can't intercept them, and a reboot clearing it is the signature of wedged shell
state, not app state. n=1, non-recurring: note it and move on. If it recurs,
capture two facts before rebooting: does the grab bar render at all, and does
gaze highlight it? (Also worth remembering: it appeared in the same era as
heavy immersive-space open/dismiss cycling — if it ever correlates with a
specific transition, file feedback with that sysdiagnose.) Not related to the
corners in any mechanical way — the corner bug lives inside your layer tree;
the grab bar lives outside it.

## Ship ruling

Do the one-build fix above — it's small, contained in code you own, and the
diagnostic and the fix are the same build. If branch 3's fallback also fails to
look right for some reason, **ship 1.2.0 square-cornered and file feedback with
Apple; do not hold the release** — every functional system is green as of
1.1.2.32, and this is chrome. Run the OTA bisect in parallel purely for the
timeline truth; whichever way it lands, you already shipped the right fix.
