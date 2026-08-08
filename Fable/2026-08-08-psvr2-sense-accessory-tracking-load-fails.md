# visionOS 26: `ar_accessory_load_from_device` fails for a PSVR2 Sense pair that enumerates as one `MFi` gamepad

## The question (one line)

On Apple Vision Pro (visionOS 26.x), a connected **PSVR2 Sense controller pair** is
delivered to GameController as **ONE controller reporting
`productCategory == "MFi"`**, never as two
`GCProductCategorySpatialController` devices — and
`ar_accessory_load_from_device()` **fails** on it even with
`ar_authorization_type_accessory_tracking` **granted**. **How do we get the Sense
pair to enumerate as spatial controllers (or otherwise obtain per-hand
`ar_accessory_anchor_t` poses) from a SDL2-based C game that also drives those
same controllers as an ordinary gamepad?**

## Why we care

The goal is small and concrete: draw Mario's own hand display lists at the
player's controller positions in VR first-person. Everything downstream of a pose
is already built and compiles — the coordinate chain, the per-eye draw, the
settings. **The only missing input is a pose.**

## Symptom (precise, device-measured)

Vision Pro, visionOS 26.x, Xcode SDK XROS26.5, PSVR2 Sense pair powered on and
paired, both controllers held:

| What | Observed |
|---|---|
| `GCController.controllers.count` | **1** (not 2) |
| `c.productCategory` | `"MFi"` — **not** `GCProductCategorySpatialController` |
| Gamepad input through SDL | **works perfectly** — sticks, face buttons, triggers, grips all drive the game |
| `ar_session_request_authorization(.accessory_tracking)` | prompt **appears**, user **allows**, handler reports **allowed** |
| visionOS **Settings** app | **no accessory-tracking / hands entry ever appears** for our app, before or after allowing |
| `ar_accessory_load_from_device(c, handler)` | **`successful == false`, `accessory == NULL`** |
| Resulting hands | none |

The in-headset status line reads exactly: **`Hands: allowed, 1 device not
trackable`**.

> The next build captures `ar_error_get_error_code()` and
> `CFErrorCopyDescription()` from the failing load and shows the code in that
> status line. If the answer depends on which error it is, say so and we will
> report it — we just do not have it in hand as of this writing.

## What we have already ruled out

1. **It is not a missing authorization request.** That WAS a real bug of ours and
   it is fixed: nothing called `ar_session_request_authorization`, so the load
   failed for want of permission and looked exactly like "device not trackable".
   Permission is now requested first, the prompt appears, the user allows it, the
   completion handler reports `ar_authorization_status_allowed`, and devices that
   connect while the user is deciding are queued and loaded afterward. **The load
   still fails.**
2. **It is not a missing Info.plist key.** `NSAccessoryTrackingUsageDescription`
   is present in `app/ios/Info-visionos.plist` (and the prompt does appear, which
   is consistent).
3. **It is not the spatial-category gate.** An earlier version only attempted the
   load for `GCProductCategorySpatialController` devices, which made the call
   unreachable. The load is now attempted on **every** connected controller
   regardless of category.
4. **It is not that the controllers are absent or asleep.** They drive the game
   through SDL at the same moment the load fails.

## Our four hypotheses, best first

### H1 — SDL2 has claimed the controllers, forcing the MFi presentation

`controller_sdl.c` (SDL 2.32) opens game controllers through the GameController
framework. SDL 2.32 predates spatial controllers entirely. Our own charter
flagged this risk before any of it was written:

> "SDL 2.32 predates spatial controllers, but verify it doesn't half-enumerate
> them (if it does, filter them from SDL so the fixed layout owns them
> exclusively)."

We never verified it. If SDL opening the device is what collapses a Sense pair
into one MFi gamepad, then the fix is to keep SDL's hands off them — but that
trades away the working gamepad input path, which Austin explicitly wants kept
(outside first-person the pair should behave like a normal controller, and today
it does).

**Question:** does opening a spatial controller via the older GameController
paths actually change how it enumerates? And if we must choose, can one process
have the pair as spatial controllers for POSES while still reading buttons — or
does claiming it one way forfeit the other?

### H2 — Spatial-controller enumeration needs something we have not declared

An entitlement, an Info.plist key, a `GCEventInteraction`-style claim, or a
minimum deployment target. This port's deployment target is **xrOS 2.0**
(`-target arm64-apple-xros2.0`) even though it is built against the 26.5 SDK and
runs on 26.x, and `GCProductCategorySpatialController` is a visionOS 26 symbol
we access under `@available(visionOS 26.0, *)`.

**Question:** does a 2.0 deployment target suppress spatial-controller
enumeration at runtime even on a 26.x device? Is there a declaration
(entitlement / plist key / capability) required before the system will present
Sense controllers as spatial controllers at all?

### H3 — Two concurrent `ar_session_t` instances, and the second one loses

We run **two** ARKit sessions:

- the VR loop's session (`sm64_vr_spike.m`), created once at loop start, running
  `ar_world_tracking_provider_t` — this is what the whole VR mode's head pose
  depends on;
- a separate session for accessory tracking (`sm64_vr_hands.m`), created lazily
  because accessories load asynchronously and controllers connect whenever they
  like, so the accessory set is simply unknown at VR-loop start.

The separation was deliberate — a failure in accessory tracking must not take
down head tracking. But `ar_accessory_load_from_device` does not take a session
parameter at all, so it is unclear whether session state can even be implicated
in a load failure.

**Question:** is more than one concurrent `ar_session_t` per app supported? Must
accessory tracking run on the *same* session as world tracking? Does
`ar_accessory_load_from_device` depend on any session being in a particular state
(running? authorized? one specific session)?

### H4 — The Sense pair genuinely is not a trackable accessory on this system

Possible, and it would end the feature — but Austin's direct experience
contradicts it: *"lots of people use the psvr2 controllers for hand tracking."*
If that is true and the pair is trackable in other apps, the difference must be
something about how this app asks.

**Question:** what does a working PSVR2-Sense accessory-tracking app do that we
do not? Is there a known-good minimal sequence?

## The one that puzzles us most

**Permission was granted, yet visionOS Settings shows no entry for our app.**
Austin checked before and after allowing. A granted authorization that leaves no
Settings row suggests the grant is not being recorded against the capability we
think it is — or that the prompt we triggered was for something adjacent. That
smells like the actual root cause, and we do not know how to interpret it.

## Code, if you want to read it

- `app/vision3d/sm64_vr_hands.m` — authorization request, device load, tracking
  provider, per-frame anchor poll, pose → game-camera transform. The whole
  feature.
- `app/vision3d/controller_vision.m:116-140` — `vr_adopt()`, where every
  controller is inventoried and registered for loading regardless of category.
- `app/vision3d/sm64_vr_spike.m` — the VR loop and its world-tracking session;
  `sm64_vr_camera_from_world()` publishes the room → game-camera transform.
- `app/ios/Info-visionos.plist:41-46` — the usage-description key.
- Everything reaches vendor through `scripts/gen-patch-0011.py`; never hand-edit
  `vendor/`.

## What we are NOT asking

How to draw the hands. That side is done: Mario's own hand display lists render
per eye with a flat primitive-colour material (his display lists carry no
combiner, geometry mode, or lights, and clearing `G_LIGHTING` makes vertex
normals read as colours — a flat colour is the one material that cannot fail
confusingly). Hand up a pose and hands appear.

---

# Second, smaller question: the VR sky dome flickers white at some angles

## Background

SM64's skybox is a fullscreen **ortho** image, which cannot surround you, so VR
drops it and `skybox.c` builds a 3D sphere from the same 32×32 panorama tiles
(ported from RaYRoD's Quest port). It is bracketed with `gDPNoOpTag` markers so
`gfx_stereo_projection()` hands it a **translation-free** EyeVP — same rotation,
no parallax, so it reads as sky rather than as a ball at arm's length.

## What was already fixed

The donor fades the panorama toward `ENVIRONMENT` for a cloud→clear effect,
justified as "the only guaranteed clear-sky color". **False in coopdx**, where
`sSkyboxColors` is a white *tint* (`{0xFF,0xFF,0xFF}` for every level but dark
JRB) — so the fade ran to pure white and the sky went white as you looked up.
Removing the fade (the dome now inherits the flat skybox's own material,
shade alpha constant 255) fixed the bulk of it.

## What remains

*"The blue sky does mostly stay blue, but in certain angles and movements, it
will stay white or flicker to white."*

Angle- and motion-dependent, intermittent, and white specifically. Our candidates,
none confirmed:

- **Display-list pool exhaustion.** The dome allocates ~3080 `Gfx` + 1536 `Vtx`
  (~50 KB) per frame. `alloc_display_list` returning NULL makes us fall back to
  the flat ortho skybox — which VR then **clips away entirely**
  (`sm64_vr_hide_background`), so a frame with no sky at all shows whatever the
  eye clear leaves. A per-quad NULL just skips that quad, leaving holes. Both are
  load-dependent, which fits "certain movements".
- **Texture-cache pressure.** 384 quads/eye each issue `gLoadBlockTexture` for
  one of 64 distinct tiles. If a lookup misses or evicts, does this renderer
  produce white?
- **Degenerate geometry at the zenith.** All 16 azimuth segments converge to a
  point; the top ring's quads collapse and the panorama's top row is squeezed
  into a singularity. Plausible shimmer source, less obviously a *white* one.
- **A missed marker.** If `sm64_gfx_sky_layer` is not set when MP is composed,
  the dome takes the ordinary EyeVP. That changes parallax, not colour — so
  probably not this, unless it also pushes the dome outside the frustum.

**Question:** which of these actually produces WHITE in this renderer, and is
there a standard way to cap a 2D panorama onto a sphere's pole that avoids both
the singularity and the fade-to-tint trap? Or is the whole "wrap the flat skybox
onto a dome" approach the wrong shape, and we should be drawing a proper sky
sphere with its own texture instead?
