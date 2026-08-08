# "Show Mario Hands" — what's known before writing it

Austin asked for his controllers to be Mario's hands in first-person (2026-08-08).
This is the research done before implementation, so the next session starts from
facts rather than re-deriving them.

## The good news: they are MARIO's hands, not stand-ins

His hands exist in the ROM as their own display lists —
`mario_left_hand_closed_shared_dl`, `mario_left_hand_open_shared_dl`,
`mario_right_hand_closed_dl` and the open/cap-holding variants
(`actors/mario/model.inc.c`). Same geometry the arms carry, so "his real hands"
is achievable rather than approximated.

## Obstacle 1: those display lists carry NO render state

    const Gfx mario_left_hand_closed_shared_dl[] = {
        gsSPVertex(...), gsSP2Triangles(...), ..., gsSPEndDisplayList(),
    };

Vertices and triangles, nothing else. Every material decision — combiner
(`G_CC_SHADEFADEA`), geometry mode, and crucially the LIGHTS — comes from the
geo layout that wraps it when Mario is drawn normally
(`actors/mario/geo.inc.c:410-425`). Drawing a hand standalone therefore means
supplying a prologue, and the failure mode is not an error: it is black hands,
or hands coloured from vertex normals read as colours. Budget a device round or
two for exactly this, and change ONE thing at a time.

Mario's lights in particular are set by the geo's ASM nodes (player colours), so
the prologue has to either set lights or clear `G_LIGHTING` and accept flat
shading — worth trying flat first, since it cannot look wrong in a confusing way.

## Obstacle 2: nothing draws in the world except the game's own display list

The hands must be drawn by the ENGINE (so they get the VR projection, the depth
buffer, and occlusion for free), not by the compositor loop, which has no access
to N64 geometry. The seam is `gfx_run()` in overlay 0011 — we already own it and
already render both eyes there, so an extra `gfx_run_dl()` per eye with a
hand-shaped display list is the natural insertion point. The matrix goes in as
`gSPMatrix(..., G_MTX_MODELVIEW | G_MTX_LOAD | G_MTX_NOPUSH)` carrying the full
model->CAMERA transform, because that is the space our EyeVP consumes.

## The coordinate chain (all pieces already exist)

ARKit world (metres) -> camera space (game units) is the inverse of what
`sm64_vr_placement()` builds, times `sVrScale`. The anti-clip already computes
exactly this for the head (`sm64_vr_spike.m`, the `sVrHeadCamPos` block) — the
hands are the same transform applied to a different point, so copy that, do not
re-derive it.

## Poses

`ar_accessory_tracking_provider` (visionOS 26+), on the ARKit session the VR loop
already runs. The provider is configured with the accessories themselves, which
come from `ar_accessory_load_from_device(GCDevice)` — already called in
`controller_vision.m` for chirality, so the loaded `ar_accessory_t` objects need
keeping rather than discarding. Then
`ar_accessory_tracking_provider_get_latest_anchors` per frame, and
`ar_accessory_anchor_get_held_chirality` / `_is_held` per anchor.
`NSAccessoryTrackingUsageDescription` is already in the plist.

NOTE: the PSVR2 pair enumerates as ONE `MFi` gamepad on this system (device log,
2026-08-08), not as two spatial controllers — so `ar_accessory_load_from_device`
may or may not have anything to load from it. **Verify that before building on
it**: if the pair is not individually addressable, there are no per-hand poses to
be had and the whole feature stops there.

## Suggested order

1. Prove poses exist at all: log the anchor count, chirality and position. If the
   MFi enumeration means no per-hand accessory, stop and report — everything
   below is moot.
2. Prove the coordinate chain with a MARKER (a plain quad at the pose), so a
   wrong transform looks wrong in an obvious way instead of hiding behind a
   possibly-wrong material.
3. Swap the marker for the hand display list plus its prologue.
4. Then the sub-options Austin asked for, which only appear when hands are on:
   grab-with-hands (proximity to the HAND rather than to Mario) and
   punch-with-hands (a thrust gesture).

## What was actually built (2026-08-08, OTA 1.1.2.18)

Austin asked for all of it in one build rather than gating on step 1, so steps
1-3 shipped together, untested in a headset.

- **Step 1's question is now ASKED, not answered.** The reason it had never been
  asked is worth recording: `ar_accessory_load_from_device` sat behind
  `controller_vision.m`'s `vr_is_spatial()` gate, which is the right gate for
  deciding who drives the N64 pad and the wrong one for poses — that call takes a
  `GCDevice`, not a spatial controller. It now runs for every controller and logs
  `[vrhands] accessory LOADED` or `[vrhands] accessory load FAILED` either way.
  **Read those lines before building anything further.**
- **Steps 2 and 3 are merged.** No marker quad: the hands draw as flat WHITE
  primitive-colour geometry, which serves the marker's purpose (a wrong transform
  is unmistakable) while already being the right material — Mario's gloves are
  white, and a flat colour cannot be silently wrong the way normals-read-as-
  colours can.
- `sm64_vr_hands.m` owns accessory loading, a dedicated ARKit session (separate
  from the VR loop's world-tracking one, because accessories load asynchronously
  and the loop's session is created once), the per-frame anchor poll, and the
  `inverse(A) * accessoryPose` chain into game-camera space.
- Settings `vrHands` / `vrHandSize` in both menus.
- **Step 4 (grab-with-hands, punch-with-hands) is NOT built** — it is pointless
  until poses are confirmed.

Known rough edge if poses do work: the hands are drawn at the very end of the
eye's display list, so they draw over the HUD as well as the world. That is
arguable rather than wrong, and it is cheap to revisit.

## Scope decided with Austin

Hands only, no arms. Mario's arms are animation-driven, not IK-driven, and his
proportions are not the player's — forcing them to reach the controllers gives
either stretched arms or hands that lag where you put them. Floating hands are
what most VR titles ship for this reason, and they read as YOURS precisely
because nothing contradicts your proprioception.
