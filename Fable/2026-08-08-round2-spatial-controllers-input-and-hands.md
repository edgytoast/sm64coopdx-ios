# ROUND 2 — SpatialGamepad landed, input broke, hands still absent

Fable: your Q1 answer was right and the declaration worked. What followed was my
own mistake, and it left three things unresolved. Austin has now spent several
device rounds on this and is out of patience with speculative builds, so I want
concrete answers before the next one.

---

## What happened since your answer

Added `GCSupportedGameControllers` / `SpatialGamepad` to the plist by hand, and —
in the **same build** — took your action 3 and filtered spatial controllers out
of SDL so the native fixed-layout backend (`controller_vision.m`) would own them.

**That build (1.1.2.22) was a total bust on device:**

- The game reported **no controllers connected** and drew the touchscreen
  controls (SDL's joystick list was empty because I had filtered the only
  devices out of it).
- **Some buttons worked, most did not** — Z and R specifically dead.
- The VR panel was therefore **unreachable** (R opens it), so none of the
  in-headset diagnostics could be read.
- No hands. Still **no accessory-tracking row in visionOS Settings**.

**The diagnosis I am confident of:** "no controllers detected" *plus* "a few
buttons still work" is only possible if the pair stopped presenting as one
aggregate MFi gamepad and became spatial controllers driven by
`controller_vision.m` directly (it writes the virtual pad without registering an
SDL joystick). **So the declaration worked.** What broke was that I removed a
working input path in the same build that introduced its unproven replacement —
`controller_vision.m`'s element names were guessed from a Mac and had never
executed. Entirely self-inflicted.

1.1.2.23 reverted the SDL filter and made `controller_vision_read` contribute
nothing, so input is back on SDL. The plist declaration stays.

---

## Q1 — The exact input mapping for a PSVR2 Sense spatial controller

I will not ship another guessed layout. Your answer gave three specifics
(prefer `GCControllerLiveInput`; thumbstick under `dpads` there rather than
`axes`; analog trigger via `pressedInput.value`). I need the rest of it
concretely enough to write once and have it work:

1. **The element names.** For a Sense controller under `GCControllerLiveInput`
   (and, if they differ, under `GCPhysicalInputProfile`): the exact identifiers
   for thumbstick, thumbstick click, A, B, grip, trigger, and menu. Names, not
   categories — `GCInputThumbstick`, `GCInputLeftTrigger`, something Sense-
   specific, or something else?
2. **Chirality before ARKit answers.** `ar_accessory_load_from_device` is async,
   so there is a window where two spatial controllers are connected and we do not
   know which is left. Is there a synchronous signal — is chirality inferable
   from GameController at all, or must input genuinely wait for ARKit?
3. **Does the aggregate MFi device persist alongside the spatial pair?** You
   flagged this as undocumented. The next build reports every controller and its
   category in the VR panel, so I will have the empirical answer — but if you
   know, it decides the whole architecture: if it persists, SDL keeps driving it
   and I never touch input again (best outcome by far).
4. **The "no controllers connected" problem.** coopdx decides whether to draw
   touchscreen controls from SDL's joystick list. A native backend that writes
   `OSContPad` directly is invisible to that check. If input must come from the
   native path, what is the least invasive way to make the game consider a
   controller present — a synthetic SDL joystick, or a coopdx-side flag?

**Underlying question:** is there any configuration where **SDL keeps driving
input unchanged** and we take *only* poses from ARKit? That is by far the
safest outcome and the one Austin actually wants (his standing instruction:
outside first-person the pair should behave exactly like a normal controller).
If SDL 2.32's generic `physicalInputProfile` branch handles two spatial
controllers acceptably, I would rather leave input entirely alone.

## Q2 — Hands still do not appear, and Settings still shows no row

With `SpatialGamepad` declared and (by inference) the pair enumerating as spatial
controllers, hands still did not draw and **no accessory-tracking row appeared in
visionOS Settings** — the same symptom as before the declaration. Your answer
predicted the row would appear "once the declaration lands and a load succeeds".

I could not read the load result on 1.1.2.22 because the panel was unreachable;
the next build fixes that and reports the load result and error code in-headset.
But since Austin is rationing device rounds, I want the failure modes enumerated
in advance:

1. Given the declaration is in place and the controllers enumerate as spatial,
   what are the **remaining** reasons `ar_accessory_load_from_device` returns
   unsuccessful?
2. Is `ar_accessory_load_from_device` expected to work on a spatial controller
   that **SDL currently has open** (`GCController` claimed via
   `physicalInputProfile`)? This is the one interaction I cannot rule out — in
   1.1.2.23 SDL owns the devices again, and if an open device cannot be loaded
   as an accessory then Q1's "leave input alone" outcome is impossible and the
   two goals are in direct conflict. **This is the single most important
   question in this document.**
3. Our two-session split: you said keep it, and consolidate only if loads
   succeed but anchors do not flow. Does that still hold now that the devices
   enumerate differently?
4. Is there any ordering requirement — must the accessory tracking provider be
   running, or the immersive space open, before a load will succeed?

## Q3 — Unrelated regression: the 2D window loses its rounded corners

Not previously asked. The visionOS **2D window** (the ordinary flat game window,
before entering VR) shows **rounded corners for roughly half a second at launch
and then becomes fully square**. It is a regression introduced somewhere in the
VR phase — the public 1.1.2 release does not have it.

What I have already checked and ruled out:

- No `cornerRadius` / `clipsToBounds` / `maskedCorners` / `isOpaque` handling
  anywhere in our code.
- `git diff` of `app/gfx/gfx_metal.mm` since the last release shows **no**
  changes to layer properties, drawable size, or frame/bounds handling.
- `git diff` of `app/vision3d/sm64_vision_host.m` and `SM64VisionApp.swift`
  shows no window or scene changes that apply at launch. The window *parking*
  code (`sm64_3d_park_window`, `UIWindowSceneGeometryPreferencesVision`) only
  runs on entering 3D/VR, long after the corners have already squared.

The timing — correct at first, wrong within half a second — reads like the
system's rounded window chrome being correct until our Metal content starts
presenting, after which something paints over the corner mask. **What squares a
visionOS window's corners once a `CAMetalLayer`-backed view starts presenting,
and what is the correct way to keep the system corner treatment?**

---

## What the next build will report from inside the headset

So the next round produces data rather than another guess:

- **Pad inventory:** controller count, each one's `productCategory`, and its
  button/dpad element counts. Settles whether the declaration took and whether
  the aggregate persists.
- **Hands status:** authorization state, load successes/failures, the
  `ar_error` code, live anchor count, and per-hand tracked flags.
- **Texture-cache wraps:** whether your white-sky diagnosis is fully closed out.

If any of the above is the wrong instrument for what you need, say so and I will
change it before Austin spends another round.

## Code

- `app/vision3d/controller_vision.m` — inventory, discovery, and the disabled
  fixed layout (`controller_vision_read`, body behind `#if 0`).
- `app/vision3d/sm64_vr_hands.m` — authorization, load, provider, anchors, pose.
- `app/ios/Info-visionos.plist` — the `SpatialGamepad` declaration and the ARKit
  usage strings.
- `overlay/assets/sdl2-visionos-compat.patch` — where the SDL filter lived
  before it was reverted; `IOS_AddMFIJoystickDevice` is the site.
