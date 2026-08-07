# VR R0 — spike findings

What the R0 spikes (VR-CHARTER §5) actually measured, so R1 starts from
evidence instead of the charter's assumptions. Spike code lives on the
throwaway branch `vr-r0-spike` (`app/vision3d/sm64_vr_spike.{h,m}` plus the
temporary hooks listed at the end); none of it ships.

Simulator: Apple Vision Pro, visionOS 27.0, lane 1. Device: Austin's M5 Vision
Pro via OTA `1.1.2.1`.

---

## R0.1 — the immersion-style contract (A7)

Three separate `ImmersiveSpace`s were declared, one per style SET, and opened
one at a time. A minimal loop cleared each view to a 50%-alpha colour and
presented; every fact the drawable exposes was dumped on frame 0 and on every
change thereafter.

| variant | style set | result on the simulator |
|---|---|---|
| 1 | `.immersionStyle(.constant(.mixed), in: .mixed)` | 1500+ frames presented, no abort. Room shows through the wash. |
| 2 | `.immersionStyle($style, in: .mixed, .full)` + 3 live switches | 2400+ frames presented, no abort. Contract dump printed ONCE — the switches did not change it. |
| 3 | `.immersionStyle(.constant(.full), in: .full)` | 2400+ frames presented, no abort. Room gone. |

**A7 path (a) is viable, pending the headset.** The shape that the recorded
`.progressive` trap warned about — a style set with more than one member,
switched live — survives `cp_drawable_encode_present` and leaves the drawable
contract byte-identical. Screenshots confirm the switch really applies and is
bidirectional: mixed (room) → full (no room) → mixed (room) → full (no room),
`work/vr-spike/v2b-{A,B,C,D}-*.png`.

Two facts worth carrying into R1 beyond the yes/no:

- **The app's own 2D window stays visible and interactive in `.full`.** The
  parked card, its curtain and the ornament are all still there
  (`work/vr-spike/variant3.png`), so the Exit control survives Full VR and the
  charter's park-don't-close rule keeps working unchanged.
- **Declaring the extra spaces does not disturb `SM64-3D`.** Re-run of the
  existing 3D path after the spike spaces were added: 1200 frames, panel intact
  (`work/vr-spike/regress-3d.png`). The independence A7 path (a) needs is real.

Simulator contract, for comparison against the device dump:

```
layout=2 (layered) foveation=0 colorFmt=71 depthFmt=252
views=1 textures=1 ratemaps=0 depthRange=[inf,0.1000] target=0
tex0 color=3840x2160 arr=1 type=3 | view0 texIdx=0 slice=0 vp=(0,0 3840x2160)
```

The simulator is MONO (one view, eye transform exactly identity), so the A3 IPD
check cannot run there and neither can stereo fusion — both are device-only, and
the device also differs in layout (`.dedicated`), foveation and rate-map count.
**R0.1 is not closed until the headset prints its own contract.**

---

## R0.2 — the frozen-pose world

`EyeVP = P · V · A` is composed once from a device anchor captured after
tracking converges, published to the engine, and returned by
`gfx_stereo_projection()` for every perspective draw. The engine's two existing
eye passes then render the whole world with it, and the loop paints each eye
over its drawable slice.

**Result on the simulator: the world renders correctly through the VR matrix
chain** (`work/vr-spike/variant1.png`). Castle grounds surround the viewer at
diorama scale, orientation upright and unmirrored, depth ordering correct
(castle in front of hills, Mario in front of the ground), and the room shows
through where the game drew nothing. Head-lock, stereo fusion and the IPD check
are device-only.

### Three findings R1 must carry

**1. The compositor is reverse-Z; the engine is not. Do not hand
`cp_drawable_compute_projection` to the engine as-is.** `drawable.h` is explicit
— "It only supports reverse-Z depth, which means the value in the texture should
be 1 for near 0 for far" — and the simulator's `depthRange` reads
`[inf, 0.1]`, i.e. an infinite far plane with near at 0.1 m. The engine renders
forward-Z everywhere (clear 1.0, less-equal), so a reverse-Z projection inverts
its depth test and sorts the world back to front. Charter A3's "always from
`cp_drawable_compute_projection`" needs one amendment: take the **asymmetric
frustum** from that matrix (recovered exactly — `tR = (m20+1)/m00`,
`tL = (m20-1)/m00`, likewise for Y, so no hand-rolled FOV) and rebuild only the
**depth mapping** forward. A3's other half — blitting the engine's depth
straight into the drawable's depth texture — therefore does NOT hold as written:
the two conventions differ, so a depth copy has to convert (and the engine
currently stores no depth at all: `gfx_metal_begin_pass` sets
`depthAttachment.storeAction = DontCare`, and one depth texture is SHARED
between the eyes). Reprojection quality is the thing at stake, so this is R1
work, not cosmetic.

**2. SM64's skybox is a fullscreen ORTHO image, and in VR it papers over
everything.** Charter A8 defers the donor's sky dome to R4, but it does not say
what happens to the existing sky — and left alone, the ortho backdrop covers the
whole view and there is nothing for the world to hang in. The
`SM64_GFX_TAG_BG_BEGIN/END` markers overlay 0011 already emits are exactly the
handle: the spike pushes the marked layer outside the frustum so it clips away.
R1 needs a deliberate decision here (drop it, or fake a far-plane dome).

**3. The engine clears its frame to OPAQUE black, so the "diorama in your room"
look needs the alpha path the donor's rung 2 describes.** The spike fakes it by
discarding near-black fragments in the copy shader — good enough to prove the
look, wrong to ship (it also keys out genuinely black geometry). The real fix is
the donor's: clear the eye targets to alpha 0 and let the compositor blend.
That is an engine-side change (`gfx_metal_begin_pass`'s clear colour), not a
loop change.

---

## Structural note for R1

The engine seam this needs — the VR branch in `gfx_stereo_projection()` — lives
inside overlay **0011**'s own hunk, so it cannot be added by a new patch without
breaking 0011's reverse probe (D6). The spike therefore extends 0011 through its
generator and re-applies (`patch -R` 0011 out of vendor → `gen-patch-0011.py` →
`apply-overlay.sh`), which is the same workflow the repo-owned `app/vision3d/`
files already use and is neither a hand-edit of `vendor/` nor a renumbering.
R1's split should be: new files + new seams in patch **0013**, and the
`gfx_stereo_projection` hook as a **0011 regeneration**. Worth confirming with
Fable before R1 lands.

---

## Device checklist (open)

Run the OTA `1.1.2.1` build, press **VR** next to 3D:

1. Does the space open and keep presenting (no abort), with `.mixed` + `.full`
   both in the style set?
2. Does **Full VR / Passthrough** switch live and both ways?
3. `[vrspike] CONTRACT` — the device's layout, view count, texture count,
   rate-map count and per-view viewports.
4. `[vrspike] IPD CHECK` — must read ~0.063 m along X. Anything else means the
   composition convention is wrong (charter A3: consult, do not sign-flip).
5. Does the world **fuse** in stereo, and does it sit at a plausible scale?
6. Frozen pose: expect the world to drift with head motion (it is rendered from
   a frozen V while the compositor reprojects against the live one). Confirming
   HOW it drifts tells R1 whether the reprojection path is behaving.
