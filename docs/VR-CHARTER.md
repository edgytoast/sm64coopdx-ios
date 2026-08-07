# VR Mode Charter — sm64coopdx visionOS

Written 2026-08-07 by Fable after analyzing RaYRoD's open-sourced Quest VR port
(`~/dev/sm64coopdx-vr-quest`, the full `vr-quest` branch from the v0.12 release
bundle) against this repo. This is the implementation charter for Opus. When a
step here collides with reality, stop and consult Fable rather than improvising
around it — see §10.

---

## 0. Mission

Add a **VR mode** to the existing visionOS app: a new ornament button next to
"3D" that opens a fully immersive space where the game world surrounds the
player at real scale — diorama on the floor, third-person in the world, and
eventually first-person from Mario's head. Same app, same binary, no separate
target. The existing "3D" panel mode stays exactly as it is.

The Quest port proves every product question (four view modes, live sliders,
menus in VR, co-op in VR all work and are fun). Our job is transplanting its
*design* onto our platform stack, not porting its OpenXR/GLES code line by line.

## 1. Read these first, in order

1. `docs/frame-map.md` — this repo's architecture in one page.
2. `~/dev/sm64coopdx-vr-quest/QUEST_PORT_NOTES.md` — the donor project's full
   session handoff **including a debugging ledger of every hard bug**. Most of
   its lessons transfer; §6.3 below maps them to visionOS.
3. Donor code, the parts we actually port:
   - `src/pc/vr/vr.h` — the platform seam (clean, no XR/GL types leak out)
   - `src/pc/vr/vr.c:398-680` — `vr_build_eye_matrix()`: the A·V·P eye math
   - `src/pc/vr/vr.c:1493-1560` — preset table + per-preset tunables
   - `src/pc/pc_main.c:274-300` — `vr_frame_is_nongameplay()` panel routing
   - `src/pc/pc_main.c:410-660` — the VR frame loop shape
   - `src/pc/pc_main.c:313-405` — anti-clip collision resolve
   - `src/pc/djui/djui_panel_vr.c` — the in-game VR options panel
   - `src/pc/controller/controller_vr.c:1-31` — input mapping *philosophy*
4. Our side, the seams we build on:
   - `app/vision3d/SM64VisionApp.swift` — scenes, ornament, mode state
   - `app/vision3d/sm64_immersive.m` — the CompositorServices loop
   - `app/vision3d/sm64_vision_host.m` — enter/exit sequencing, frame poll
   - `vendor/sm64coopdx/src/pc/gfx/gfx_pc.c:708-791` — `gfx_stereo_projection()`,
     the projection choke point (`GFX_PROJECTION()` hook)
   - `app/gfx/gfx_metal.mm:1280-1501` — per-eye offscreen render targets

## 2. Product definition

- **Entry** (Austin, 2026-08-07): mirror the existing 3D toggle exactly. In
  flat mode the ornament shows "3D" and "VR" (plus gear); inside either mode
  the button becomes "Exit" and returns to the flat panel — same seamless
  round-trip 3D does today (`SM64VisionApp.swift:147-163`).
  `SM64AppModel.immersive: Bool` becomes a tri-state mode
  (`flat / panel3D / vr`); the `.onChange` handler picks which
  `ImmersiveSpace` id to open. Direct 3D↔VR switching is a stretch goal:
  visionOS allows one immersive space at a time, so it sequences as
  dismiss-then-open (brief system transition; engine keeps running). Scope may
  evolve as Austin plays with it.
- **View modes inside VR** (Quest preset table, minus Theater — our "3D" panel
  *is* Theater, already shipped): **Diorama** (world floats in your room like a
  toy), **Third-person** (over Mario's shoulder at larger scale), and later
  **First-person** (life-size, eye at Mario's head). Mode cycling + per-mode
  remembered tunables, exactly per the donor.
- **Menus/title/loading**: any non-gameplay frame automatically presents as
  the flat game on a world-locked panel (the donor's "flatscreen-on-a-panel"),
  which for us is literally the existing 3D-mode panel presentation.
- **Input**: gamepad AND PSVR2 Sense controllers (Austin has Sense hardware
  to test). Gamepad is the R1 baseline — already works through
  `controller_sdl` + `GCEventInteraction` — and remains fully supported in
  every mode. Sense controllers land as their own phase (R3) with the donor's
  fixed-layout design; see A10. Head pose never drives the game camera in
  Diorama/Third-person — same rule the panel mode already enforces.
- **ROM/asset handling**: unchanged; ours already works and is
  platform-appropriate. Nothing to take from the donor's Android ROM scan.

## 3. Architecture decisions

**A1 — One new backend behind the donor's seam shape.** Create
`app/vision3d/sm64_vr.h/.c` mirroring the *shape* of the donor's `vr.h`
(presets, tunables, begin-frame/eye matrices/recenter accessors), implemented
against CompositorServices + ARKit **C APIs** (`cp_*`, `ar_*` — confirmed
present in the XROS SDK; the donor's `vr.c` structure maps function-for-function).
Keep names close to the donor's so diffs against it stay readable.

**A2 — Two full display-list walks per frame; NO tape replay in v1.** The donor's
stereo draw-stream replay (camera-space `cx..cw` capture + `uVrVP` uniform +
recording shim) exists because GLES driver submission overhead doubled their
frame cost. We already render the complete frame **twice** per frame in 3D mode
at panel-SSAA resolutions on Metal, at rate, on device. VR eye buffers are
*smaller* than our current SSAA targets. So v1 renders each eye as an
independent full walk with that eye's matrices — culling/fog/winding stay
correct for free because everything is computed per eye on the true projected
values. The replay is performance insurance only (§7).

**A3 — Matrix injection at the existing choke point.** For eye passes, the
`GFX_PROJECTION()` hook (`gfx_pc.c:717-791`) returns the donor's composed
`EyeVP = A · V · P` instead of the game's projection:
- `A` (camera-space → anchor placement): donor `vr.c:521-538` — diorama scale
  (default 1200 game-units/m), height, distance, anti-clip offset.
- `V` (world → eye): from `origin_from_anchor` (device anchor pose) ×
  `cp_view_get_transform` (eye-from-device), inverted, converted
  column-major/simd → fast3d row-vector (transpose). Apply the donor's 6DoF
  damping, stereo-separation scale, and yaw recenter (`vr.c:464-516, 609-616`)
  in this space.
- `P`: **always from `cp_drawable_compute_projection`** (per-view, asymmetric),
  never hand-rolled — this bakes in the drawable's depth conventions so the
  engine's depth buffer can be blitted straight into the drawable's depth
  texture. Near plane 0.05 m (donor's decal z-fight lesson), far scaled to
  world size (`vr.c:551-560`).
- Ortho (2D) draws: a fixed plane transform instead — see A6.

Verification step, non-negotiable: log both eye positions the first time
through — they must differ by ~0.063 m (IPD) along eye-space X, or the
composition order/convention is wrong. Cross-eyed or diverging stereo means a
transpose or inversion slipped; consult Fable before "fixing" signs by feel.

**A4 — Pose flow: compositor thread computes, engine renders, per-frame
rendezvous.** Extend the existing phase-lock (`sm64_pace_signal` /
`sm64_3d_wait_for_compositor_frame`, `sm64_immersive.m:565-592`, overlay 0012)
into a matrix handoff: compositor loop queries the drawable, queries the device
anchor at `cp_frame_timing_get_trackable_anchor_time`, calls
`cp_drawable_set_device_anchor`, computes per-view `EyeVP`, publishes them,
signals; the engine renders both eyes into its existing offscreen textures with
*those exact matrices*; the compositor blits color+depth full-slice into that
same frame's drawable and presents. Timeout → re-present last pair (compositor
reprojection covers a dropped frame). This keeps `gfx_metal`'s command queue
and threading model intact — the agent-verified alternative (engine renders
directly into drawable textures) inverts the threading model and is not worth
it for v1.

**A5 — Non-gameplay frames auto-fallback to the panel.** Port
`vr_frame_is_nongameplay()` (donor `pc_main.c:274-300`). When true, skip eye
passes; render the flat frame once and present it on the world-locked panel
quad the 3D mode already draws (`sm64_immersive.m:814-928` path, reused inside
the VR space). This gives menus, title, act-select, and the ROM setup screen a
finished look on day one.

**A6 — HUD and dialogs on a fixed head-locked plane, drawn in-scene.** The
donor composites a head-locked HUD via an OpenXR quad layer; visionOS gives us
one stereo drawable, so 2D must be drawn *inside* the eye passes. Route the
ortho branch of `gfx_stereo_projection` to a fixed plane ~1.5 m ahead in eye
space (both eyes, correct disparity for that depth — zero-disparity HUD over a
near world causes rivalry). This also honors the standing decision from the 3D
work: dialogs stay on a flat plane (see memory: dialog diplopia — forward text
doubles; do not re-attempt 3D-floating dialog text). If HUD-in-eye-pass drags
past a day of fighting, fall back to hiding the HUD (`gMenuHideHud`) for the
dev build and consult.

**A7 — Immersion style: `.mixed` baseline, plus a true Full VR option.**
Decided with Austin 2026-08-07 (revised): the player chooses their
surroundings — **Passthrough** (likely default: the world in your real room,
the donor's "MR diorama" showcase for free), **Dimmed** (the existing
perceptual dim layer, `sm64_3d_set_dim` / `sm64_immersive.m:198-204, 389-394`,
as a slider), **Dark** (dim at 100%), and **Full VR** — a genuine
`.full`-style space, not dim-to-black. Build Full VR so Austin can judge it
in-headset; whether it *ships* is decided after he sees it next to Dark.
Implementation paths, in preference order: (a) one "SM64-VR" space with
`.immersionStyle(selection:, in: .mixed, .full)` switching styles live — but
this is exactly the shape of the recorded trap (merely *allowing*
`.progressive` on the existing space changed the drawable contract and aborted
`cp_drawable_encode_present`, `SM64VisionApp.swift:243-247`), so R0 must prove
the `.mixed`+`.full` set is contract-stable before anything builds on it;
(b) fallback: a separate fixed-`.full` space id, switched via
dismiss-then-open. Never touch the existing "SM64-3D" space's style, and never
touch `maxRenderQuality` (recorded abort, `SM64VisionApp.swift:123-125`).

**A8 — Sky**: v1 Diorama/Third-person render over passthrough (mixed) or the
existing dimming layer — no sky dome. The donor's world-locked sky-sphere
(`skybox.c` dome build + rotation-only sky VP, `vr.c:626-640`) is required
only for First-person and ports in R4.

**A9 — Recenter + comfort:** port the donor's startup yaw-recenter-on-gaze and
explicit recenter (`vr.c:483-497`), 6DoF damping slider (`sHeadScale`), and
stereo-separation scale. Settings rows go in the existing declarative table
(`sm64_vision_settings.m:117-144`), defaults in `sm64_vision_host.h:37-46`.

**A10 — Two input paths, one pad; fixed layout on Sense (decided 2026-08-07).**
- **Gamepad**: the unchanged SDL path (`controller_sdl.c`), user binds apply,
  works in every mode including Full VR. Nothing to build.
- **PSVR2 Sense**: a new backend registered next to SDL in
  `controller_entry_point.c` (donor precedent: their VR backend sits beside
  sdl/touchscreen), adopting the donor's fixed-layout philosophy
  (`controller_vr.c:1-31`): controller inputs map straight to the N64 pad,
  deliberately NOT through gamepad binds (inherited flat-screen binds
  scramble VR controllers in ways that read as wrong-hand bugs — their ledger
  paid for this). DJUI key events carry gamepad-button identity so menus,
  chat, and bind capture work unchanged. Start from the donor's exact layout
  (left stick move / right stick camera, A jump / B punch, triggers Z+R,
  grips grab-gated on something grabbable in reach, menu tap=Start
  hold=chat, right-stick click tap=mode-cycle hold=recenter) and adjust by
  feel in the headset.
- **Plumbing**: buttons/sticks natively via GameController framework —
  `GCProductCategorySpatialController` (visionOS 26+); SDL 2.32 predates
  spatial controllers, but verify it doesn't half-enumerate them (if it
  does, filter them from SDL so the fixed layout owns them exclusively).
  Poses via `ar_accessory_tracking_provider` on the existing ARKit session
  (`accessory_tracking.h`: anchors expose pose, velocity, chirality,
  is-held). Needs `ar_authorization_type_accessory_tracking` plus the
  matching usage-description key in `app/ios/Info-visionos.plist` (verify
  the exact key name against current docs). Per-hand rumble through the
  controller's haptics, donor's burst-rumble pattern.
- **Behavior by device**: same N64 pad output either way. Sense adds the VR
  gestures (grab/throw, recenter hold, per-hand rumble) and ignores custom
  binds; gamepad keeps custom binds and uses the settings-row recenter. Both
  may be connected simultaneously — both feed the pad (donor precedent).
  When controllers doff/disconnect, release everything held (donor:
  `controller_vr.c` releases all state on focus loss so buttons never stick).

## 4. Port / build / skip

| Donor piece | Verdict |
|---|---|
| `vr_build_eye_matrix` A·V·P math, damping, recenter | **Port** (R1) |
| Preset table + per-preset tunables | **Port** (R1/R2) |
| `vr_frame_is_nongameplay` panel routing | **Port** (R1) |
| Anti-clip collision anchor pushback | **Port** (R2) |
| VR options DJUI panel | **Port, adapted** to our settings sheet first (R2); DJUI panel later if wanted |
| First-person: FP sync, network-reset survival (`network.c`), flip-cam single-call axis+angle, world-scale eye-height | **Port** (R4) |
| Yaw-only right stick (their first player feedback) | **Adopt as FP default** (R4) |
| Sky dome | **Port** (R4) |
| Camera-space capture + `uVrVP` + tape replay | **Skip v1**; §7 contingency |
| OpenXR session/swapchain/layer code, EGL/GLES, MSAA probe | **Skip** — replaced by CompositorServices |
| `controller_vr.c` layout, grab gating, rumble bursts, release-on-doff | **Port the design** as the Sense backend (R3, A10); the OpenXR action machinery itself is replaced by GameController + accessory tracking |
| Android ROM scan, asset staleness machinery, APK packaging | **Skip** — ours is solved |
| On-screen keyboard, world-locked chat | **Defer** — we have a hardware/virtual keyboard story via the system; revisit after R4 |

## 5. Phases

Each phase ends with a device-verified build staged through OTA
(`~/dev/OTA-PUBLISHING.md`, `stage-ota.sh`, notes ≤420 chars) as an
OTA-only dev version (§8).

**R0 — Spikes (throwaway branch, no patch).**
1. Add `ImmersiveSpace(id: "SM64-VR")` cloning the minimal loop: clear each
   view to a color (partial alpha to confirm passthrough shows through),
   present. Test three configurations in sequence: `.mixed` only, then
   `.immersionStyle(selection:, in: .mixed, .full)` including a live style
   switch, then `.full` only. Record which survive `cp_drawable_encode_present`
   and whether the drawable contract (texture count/layout) changes between
   styles — this decides A7 path (a) vs (b).
2. Frozen-pose world: feed a hardcoded `A·V·P` (device anchor captured once)
   through `gfx_stereo_projection`'s perspective branch and full-slice blit
   both eyes. Pass = the castle hangs in space, stereo fuses, IPD log check
   (A3) passes. This is the "panel became infinite" milestone; head *rotation*
   stability comes with live per-frame poses in R1.

**R1 — Diorama MVP (patch 0013).**
- `app/vision3d/sm64_vr.c/.h` (eye math, presets, recenter, tunables),
  VR path in the compositor loop (per-frame anchor→matrices→rendezvous→blit
  color+depth→present), tri-state `SM64AppModel` + "VR" ornament button +
  `sm64_mode_enter(int)` generalizing `sm64_3d_enter` (reuse offscreen-first /
  curtain / park / wait-for-stop sequencing verbatim), non-gameplay panel
  fallback, gamepad plays.
- Files: new sources in `app/vision3d/` wired via `vision3d.cmake` (never a
  CMakeLists hunk — 0011's precedent); `-fobjc-arc` per-file for new `.m`.
- Acceptance: enter VR from ornament → castle grounds diorama in your room,
  world-locked under head motion (no shake, no seam), menus readable on the
  panel, exit → window restored; ~11 ms frame at 90 Hz on device; enter/exit
  ×10 without wedging (the boot-thread trap in `sm64_vision_host.m:534-547`
  means all new "main-thread after boot" work goes in `sm64_3d_frame_poll`).

**R2 — Modes + comfort (patch 0014).** Third-person preset, per-preset
remembered tunables, settings rows (world scale, stereo, damping, height,
distance, recenter button), anti-clip, HUD plane polish, the
Passthrough/Dimmed/Dark/Full-VR surroundings setting from A7 (default
Passthrough; Full VR included for Austin's evaluation, ship decision after),
D-pad-up mode cycle (donor `pc_main.c:497-503`).

**R3 — PSVR2 Sense controllers (patch 0015).** The A10 backend:
GameController discovery + fixed layout + DJUI key events with gamepad
identity, accessory-tracking authorization + poses, grab-gated grips,
recenter/mode-cycle stick gestures, per-hand rumble. Acceptance: full game
and all menus playable with the Sense pair alone on device; gamepad still
works alongside; connect/disconnect mid-session never sticks a button.

**R4 — First-person (patch 0016).** FP preset re-assert loop + network-reset
survival + flip-cam (donor's one-call angle+axis API — do not split them),
world-scale eye-height trick, sky dome, yaw-only stick default in FP,
comfort review. This is the phase most likely to need Fable consults.

**R5 — Perf insurance (only if a phase misses 90 Hz).** See §7.

**R6 — Public release.** Public 1.2.0 (feature release: minor bump is
justified; confirm with Austin), OTA + GitHub matching, SideStore source
refresh rides the release workflow, release title per convention
(`sm64coopdx-visionos 1.2.0`).

## 6. House rules and the trap ledger

### 6.1 Repo discipline
- Source of truth is `app/`; `vendor/` is generated by `apply-overlay.sh`.
  Never hand-edit `vendor/`. New work = patch 0013+ via a `gen-patch-00NN.py`
  following 0011/0012's precedent. Respect hunk ownership ("D6"): land in
  virgin territory or CMake extension points.
- Any `vendor/sm64coopdx/src/pc/gfx/gfx_pc.c` seams must not collide with
  patches 0007/0011/0012's regions.

### 6.2 Platform traps already paid for in this tree
- Engine boot via `performSelector:afterDelay:`, never a main-queue block
  (`sm64_vision_host.m:534-547`). The main thread never returns from
  `sm64_engine_main`; post-boot main-thread work lives in the frame poll.
- `.progressive` in the *existing* space's style set aborts present; keep the
  two spaces' configurations independent. `maxRenderQuality` aborts — leave it.
- The 2D window must stay alive in any immersive mode (SDL UIWindow, ornament,
  audio session); park + curtain, don't close.
- Simulators: lane rules + always `simctl shutdown` when done (see ~/dev
  CLAUDE.md). visionOS device availability per lane table.

### 6.3 Donor ledger, translated to our stack (read the originals in
`QUEST_PORT_NOTES.md` §"debugging ledger")
- **World shakes with head sway** → the pose you render with must be the pose
  the compositor reprojects against: always `cp_drawable_set_device_anchor`
  with the anchor used to build `V`, queried at the frame's trackable-anchor
  time. Never render with a smoothed/adjusted pose while presenting the real
  one — apply damping in `A`/world placement, not to the submitted pose.
- **Eye seam / stale scissor rectangle** → fast3d's viewport/scissor caches
  bake dimensions at apply time; poison `rendering_state.viewport/scissor` at
  every pass entry with different target dimensions (donor
  `gfx_pc.c:2408-2426`; our 3D mode may already cover this — verify, don't
  assume).
- **Black screen, frames still flowing** → on Metal this is a nil/mismatched
  attachment rather than FBO incompleteness, but the shape recurs: validate
  render-target/depth pairing when creating VR eye targets; log actual sizes.
- **Frame cost dwarfs per-phase buckets** → hunt for work *outside* the
  buckets (their desktop mirror ≙ our parked 2D window's render: in VR mode,
  ensure the flat path renders only when the panel fallback needs it).
- **Refresh/pacing** → the compositor's timing is the only pacer; size
  interpolation from measured cadence (`cp_frame_predict_timing`), never a
  hardcoded 90.
- **"Feels wrong" stick signs** → fix at the consuming mode's fold, never the
  shared source; both camera-axis signs are set by feel in the headset, not
  derived on paper.
- **Measure on second boot**, after any install that re-copies assets.

## 7. Performance contingencies (gate: a phase can't hold 90 Hz on device)

In order of preference:
1. Lower eye render scale (donor shipped a 0.4–1.0 slider) + foveation is
   already on (`.dedicated` layout + rasterization rate maps in the loop).
2. Cut the second CPU walk: port the donor's camera-space capture
   (`gfx_pc.c:1209-1239`, `cx..cw` fields) + per-eye GPU matrix — on Metal
   as a per-draw uniform, or as true vertex amplification into a `.layered`
   drawable (Apple-native single-encode stereo; requires the layered layout
   instead of `.dedicated` — check foveation interaction).
3. Full tape replay port (donor `gfx_pc.c:668-900, 2360-2508`) — last resort;
   Metal encode overhead is far below GLES driver overhead, so expect never.

## 8. Versioning & delivery (Austin's rules — do not invent)

- Dev builds during R0–R5: OTA-only, fourth component on the current public
  version (`1.1.2.1`, `1.1.2.2`, …), staged via `stage-ota.sh`, meaningful
  `--notes` every time, one `/ota/<name>/` page.
- Public VR release: one three-component version on OTA **and** GitHub
  (proposal: `1.2.0`), SideStore source regenerates from the GitHub release.
- Check `lib/coopnet/**` on any upstream fold-in that lands mid-project
  (memory: upstream coopnet fixes live in a prebuilt .a we don't link).

## 9. Decisions from Austin (2026-08-07)

1. **Ornament**: mirror the 3D pattern — "3D" and "VR" buttons in flat mode,
   "Exit" while inside a mode, seamless round-trips. Direct 3D↔VR switching
   as a stretch (dismiss-then-open). Scope may evolve as he plays with it.
2. **Default view mode**: Diorama (Fable's recommendation — safest comfort,
   and it's the showcase). Provisional; revisit after Austin has tried it.
3. **Surroundings** (revised same day): user's choice of Passthrough /
   Dimmed / Dark / **Full VR** — the last being a real `.full`-style space,
   which Austin wants built as an option and will judge in-headset before
   deciding whether it stays (see A7). Default likely full passthrough.
4. **First-person in 1.2.0 vs 1.3**: deferred until R4's gate — don't block
   on it.
5. **Input** (2026-08-07): both gamepad and PSVR2 Sense controllers, with
   deliberately different behavior (fixed layout + VR gestures on Sense,
   custom binds on gamepad) — see A10. Austin has Sense hardware for R3
   testing; Full VR / first-person are expected to pair naturally with them.

## 10. When to stop and consult Fable

Bring the failing artifact (log lines, IPD dump, screenshot) rather than a
symptom description:
- Stereo won't fuse / cross-eyed / world swims — matrix convention issue; do
  not sign-flip by feel (that's how the donor lost days).
- `cp_drawable_encode_present` aborts or drawable contract surprises in R0.
- Judder that survives correct pacing (suspect the rendezvous timeout path).
- HUD/dialog depth fights (A6) past a day of effort.
- Any phase's acceptance criteria failing for a reason not in §6.
- Anything that tempts you to edit `vendor/` directly or renumber patches.
