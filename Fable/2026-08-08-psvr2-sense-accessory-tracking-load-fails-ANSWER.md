# ANSWER — Sense pair enumeration, and the white sky

Fable, 2026-08-08. Both questions resolved to specific mechanisms with
code-level evidence; each has a ranked action list. Read the verdicts, then the
details.

---

# Q1: `ar_accessory_load_from_device` fails / pair enumerates as one MFi gamepad

## Verdict

**H2 is correct, in its Info.plist form — and it is a documented requirement,
not a quirk.** The app must declare spatial-game-controller support via the
`GCSupportedGameControllers` key with a **`SpatialGamepad`** profile. Without
that declaration the system presents the Sense pair to the app as a single
aggregated MFi-category gamepad — a compatibility presentation — and an
aggregate virtual gamepad is not a trackable accessory, so
`ar_accessory_load_from_device` correctly fails on it (error 1200,
`ar_accessory_tracking_error_code_accessory_loading_failed`, the only accessory
error code that exists — don't read meaning into it beyond "load failed").

Evidence:
- Apple's WWDC25 session *Explore spatial accessory input on visionOS* (session
  289): support is declared "to the plist via the Xcode capabilities editor…
  ticking the box **Spatial Gamepad**", alongside the Accessory Tracking Usage
  description you already have.
- Apple Developer Forums thread 804722 (PSVR2 quirks, Apple Frameworks Engineer
  participating) shows the raw key:
  ```xml
  <key>GCSupportedGameControllers</key>
  <array>
      <dict>
          <key>ProfileName</key>
          <string>SpatialGamepad</string>
      </dict>
  </array>
  ```
  (The thread also shows an array-of-strings variant; the dict/ProfileName form
  matches `GCSupportedGameControllers`' long-standing documented schema from
  tvOS — use the dict form.)
- Apple's article *Discovering and tracking spatial game controllers and styli*
  (GameController documentation) is the canonical reference.
- Community how-to (Step Into Vision, "How to set up and track spatial
  controllers") confirms the full working sequence end-to-end and warns:
  **Xcode 26's capability editor has a bug that can damage/remove existing
  ARKit plist values when ticking Spatial Gamepads — edit
  `app/ios/Info-visionos.plist` by hand instead.** Given our plist carries the
  ARKit usage strings, hand-edit only.

### Per-hypothesis rulings

- **H1 (SDL claimed them, forcing MFi)** — wrong mechanism, right worry.
  Enumeration presentation is decided by the app's *declaration*, not by who
  opens the device. But SDL still matters after the fix — see "SDL will grab
  them" below. The charter's A10 warning ("verify SDL doesn't half-enumerate
  them") is now confirmed as mandatory work, just downstream of the plist.
- **H2 (missing declaration)** — correct, as above. The **deployment target is
  NOT implicated**: capability presentation keys are read at runtime and the
  binary links against the 26.5 SDK. No target change needed.
- **H3 (two ar_sessions)** — not the cause of this failure;
  `ar_accessory_load_from_device` is session-independent (free function, talks
  to the system accessory registry). Keep your deliberate two-session split. If,
  *after* the plist fix, loads succeed but anchors never flow from the provider,
  the first consolidation test is running the accessory provider on the
  world-tracking session — but don't do it preemptively.
- **H4 (not trackable on this system)** — disproven; shipping apps (Pickle Pro,
  ALVR) track Sense pairs via exactly this API.

### The Settings-row mystery

Consistent with the same root cause: the app never registered as a
spatial-accessory client (no declaration), so there was nothing to hang a
Settings row on, while the authorization *grant* itself still recorded
(authorization and enumeration are separate systems). Expect the row to appear
once the declaration lands and a load succeeds. If loads succeed and the row
still never appears, ignore it — it's cosmetic at that point.

## What to expect after the one-line fix

1. `GCController.controllers` should contain **two** controllers with
   `productCategory == GCProductCategorySpatialController` (one per hand).
   Whether the aggregate MFi controller *also* remains is undocumented —
   **log every controller + category on connect as the first diagnostic.**
2. Each spatial controller exposes: 1 clickable thumbstick, buttons A/B, grip,
   trigger, menu (PS button reserved by the system). Per the forums thread:
   prefer `GCControllerLiveInput`; the thumbstick lives under `dpads` there
   (under `axes` on `GCPhysicalInputProfile`); analog trigger value via
   `pressedInput.value`. Touch (capacitive) events had a system bug fixed in
   visionOS 26.3; grip/trigger *proximity* is not exposed at all.
3. `ar_accessory_load_from_device` on each spatial controller should return an
   `ar_accessory_t`; feed both into the accessory tracking configuration →
   provider → session run → anchors with chirality. Your queued-load design in
   `vr_adopt()` already handles the async arrival correctly.

## SDL will grab them — plan for it now

Verified in our vendored SDL (2.32,
`vendor/sm64coopdx/lib/SDL2-source/src/joystick/iphoneos/SDL_mfijoystick.m:488-511`):
with `ENABLE_PHYSICAL_INPUT_PROFILE`, SDL accepts **any** GCController through a
generic branch (vendor=Apple, product=4) and maps its
`physicalInputProfile.elements` to axes/buttons. So once the pair enumerates as
two spatial controllers, SDL will open both halves as two odd half-gamepads and
the game will see phantom pads.

- Filter them out of SDL (skip in the add path when `productCategory` equals
  the spatial-controller string — log the exact string first, then match it;
  route the change through the existing SDL compat patch mechanism).
- Feed the game from the native fixed-layout backend instead (charter A10):
  poll the two spatial controllers via GCControllerLiveInput and write the
  virtual pad. `controller_vision.m`'s inventory is the natural home.
- If the aggregate MFi presentation happens to persist alongside the spatial
  pair: keep SDL on the aggregate (binds keep working everywhere), use the
  spatial pair for poses only — best of both. Still filter the two spatial
  halves out of SDL either way.
- Memory note 3 ("pair enumerates as one MFi gamepad, SDL drives it, correct
  behaviour") becomes **stale** the moment the plist key lands — update it.

## Ranked actions

1. Add the `GCSupportedGameControllers`/`SpatialGamepad` dict to
   `app/ios/Info-visionos.plist` **by hand** (Xcode 26 capability-editor bug).
2. Build, run, and log the controller inventory (count + categories) and the
   `[vrhands]` load results. This single run answers everything downstream.
3. Wire the SDL filter + LiveInput polling per above (shape depends on whether
   the aggregate persists).
4. Only if loads succeed but anchors don't flow: try the accessory provider on
   the world-tracking session (H3's residue).

---

# Q2: the sky dome flickers white at some angles

## Verdict

**None of your four candidates paints white — but the texture cache does, and
the dome is what pushed it over.** The mechanism, confirmed in code end-to-end:

1. `gfx_pc.c:343-350`: when the texture-cache pool fills, the "invalidate
   everything and start over" path only resets `pool_pos = 0`. It does **not**
   clear the hashmap or the nodes (that's `gfx_texture_cache_clear`, which this
   path does not call). Recycling then hands out pool slots whose `texture_id`s
   are still referenced by stale hashmap chains — and every re-import after the
   wrap **overwrites the GPU texture of a recycled slot**.
2. `gfx_metal.mm:1090-1109` (`gfx_metal_upload_texture`): re-import to an
   existing same-size texture goes through **`replaceRegion:` on the live
   `MTLTexture`** (`MTLStorageModeShared`). Metal does not snapshot texture
   contents at encode time — a mid-frame `replaceRegion:` retroactively changes
   what **already-encoded draws in the same command buffer** sample when it
   executes. (GL semantics hid this class of bug; Metal exposes it.)
3. The sky is drawn **first** in the frame and its tiles are among the oldest
   pool entries — first recycled, and with the most subsequently-encoded frame
   left to overwrite them. The overwriting content skews white: DJUI's font
   atlas and panel textures are white-heavy.
4. Why now: the flat skybox loads a ~3×3 window (~9-12 distinct tiles); the
   dome loads **all 80 tiles every frame**. And the pool (`MAX_CACHED_TEXTURES`
   4096, `gfx.h:28`) is shared with **DynOS texture preloading**
   (`gfx_pc.c:577`), so with packs preloaded it can sit near capacity, where the
   dome's +80 working-set is exactly the nudge that starts wrapping.

Angle-dependence fits: the dome DL itself is identical every frame (all 80
tiles, no culling), so a broken *region* or a *load-dependent* mechanism is
required — wraps happen on texture-heavy views, and which slots get stomped
depends on scene content. "Stays white" at a heavy angle = wrap every frame
there; "flicker" near the threshold.

Your candidates, ruled: **pool exhaustion → fallback → gap** shows the eye
clear, which is **black** (`gfx_metal.mm:1571`) or alpha-keyed passthrough —
never white (also: the gfx pool is 4 MB, exhaustion is unlikely). **Texture
cache pressure** — right family, and the mechanism is the above. **Zenith
degeneracy** — real but produces shimmer/pinching, not white; cosmetic, defer.
**Missed marker** — changes parallax, not colour; you'd already ruled it right.

## Discriminating test (do this first — one build)

Increment a counter at the wrap site (`gfx_pc.c:345`) and surface it in the
in-headset status line. Reproduce the flicker. If wraps correlate with white,
done. (Also watch for the perf signature: a wrap cascades stale-chain misses
into mass re-imports — the donor's profiler comment at their `gfx_pc.c:356`
warns about exactly this cost class.)

Secondary probes if somehow uncorrelated: magenta eye-clear build (separates
"missing coverage" from "painted white" — missing coverage turns magenta), and
a single-tile dome variant (separates texture churn from geometry).

## Fixes, in order

1. **Correctness (do regardless):** in `gfx_metal_upload_texture`, never
   `replaceRegion:` into a texture that may be referenced by encoded draws —
   when `t.texture != nil`, allocate a **fresh `MTLTexture`** and assign it
   (ARC keeps the old one alive for the already-encoded frame). This makes all
   cache recycling safe on Metal permanently, and it's a few lines.
2. **Honest wrap:** make the overflow path actually invalidate — clear the
   hashmap and node addresses (as `gfx_texture_cache_clear` does) instead of
   only resetting `pool_pos`, so stale chains can't alias recycled slots.
   Optionally also bump `MAX_CACHED_TEXTURES` so wraps stay rare with DynOS
   packs + the dome's 80 tiles resident.
3. **Stop the interpolated-frame dome waste (found while tracing, fix
   regardless):** `patch_mtx_interpolated`
   (`src/game/rendering_graph_node.c:~337`) re-invokes the background geo node
   every interpolated frame, so `build_skybox_sphere_vr` builds and **discards**
   a fresh ~50 KB dome twice per tick (the flat path survives this because it
   patches its cached `gBackgroundSkyboxGfx`/`Mtx`/verts in place). Mirror that
   contract: cache the dome DL in a `gVrSkyDomeGfx`-style global on the build
   frame; on `gRenderingInterpolated` frames return the cached DL — and do
   **not** fall through to `init_skybox_display_list` on interpolated frames
   (its interpolated branch returns `gBackgroundSkyboxGfx`, which under VR is
   NULL/stale since the flat path never builds).
4. Minor, later: hoist the per-quad `gDPSetEnvColor` (identical all 384 times)
   to once per build; zenith cap polish only if it's visible after the above.

**Is the dome the wrong shape? No.** The donor shipped this exact shape on
Quest; the flicker is a renderer-infrastructure bug (Metal-specific texture
lifetime) that the dome merely exposed by widening the texture working set.
Keep the dome.

---

Sources for Q1: Apple *Discovering and tracking spatial game controllers and
styli* (GameController docs), WWDC25 session 289 *Explore spatial accessory
input on visionOS*, Apple Developer Forums thread 804722, Step Into Vision
"How to set up and track spatial controllers" (Xcode 26 plist-bug warning).
