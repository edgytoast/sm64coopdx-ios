#!/usr/bin/env python3
"""Overlay patch 0011: visionOS stereoscopic 3D — the "screen in the room".

Phase 2. Puts the game on a world-locked panel floating in the user's room,
rendered per-eye for real depth. Everything platform-specific lives in the
repo-owned app/vision3d/ files this patch packages; the edits to vendor code are
deliberately two small, surgical seams — and CMakeLists.txt is not touched at all.

WHAT THIS ADDS, AND WHY EACH SEAM IS WHERE IT IS

1. src/pc/vision3d/*  (7 new files, packaged from app/vision3d/ per D-010)
   The SwiftUI @main + ImmersiveSpace, the CompositorServices render loop, the
   host/transition shell, and the settings table. New files, so /dev/null hunks:
   no context, no D6 exposure.

2. src/pc/gfx/gfx_pc.c — the per-eye projection AND both-eyes-per-frame.
   gfx_pc.c is touched by NO other overlay patch, which is precisely why both
   engine-side seams live here.

   a) The projection (guide §2.4 "secret #2"). gfx_pc has no separate view
      matrix to shift — the game bakes view*model into the modelview stack — so
      the eye offset is FOLDED INTO the projection alongside the off-axis skew.
      Vertices compute v * MV * P (row-vector convention: the vertex loop at
      :810-813 reads MP[3][j] as the translation row), so v * MV * T * P ==
      v * MV * (T*P), and (T*P) differs from P only in row 3. Same result, and
      the modelview stack is never touched.

      Injected at the TWO mtxf_mul(rsp.MP_matrix, modelview, P) sites (:708 and
      :716) rather than at the P_matrix load (:690-695). That is not a
      preference: rewriting rsp.P_matrix in place would compound the skew on a
      subsequent G_MTX_PROJECTION|G_MTX_MUL, and would corrupt the ortho
      predicate that reads it. Composing an eye-adjusted COPY at the two
      composition sites covers 100% of geometry with zero state mutation
      (docs/frame-map.md:83-107).

      ORTHO vs PERSPECTIVE via the gate `rsp.P_matrix[3][3] > 0.5f`, the tree's
      OWN predicate (already used verbatim by gfx_adjust_x_for_aspect_ratio :728).
      The ortho branch is no longer a pass-through (STEREO-COMFORT batch):
        - P1-a: the skybox (SM64's clouds are ORTHO) gets far-plane INFINITY
          disparity (a*e/C) so the backdrop sits BEHIND the world instead of on
          the panel in front of the mountains painted in it ("disorienting
          clouds"). The background layer is identified by the gDPNoOpTag markers
          skybox.c now emits (2c), handled in ext_gfx_run_dl's G_NOOP case.
        - P1-b: the HUD/dialog/DJUI/nametag ortho layer gets a small CROSSED
          disparity (-hud*a*e/C) so it floats slightly IN FRONT of the panel and
          wins the depth-order fight with popped-out geometry ("Lakitu message
          not in the foreground"). Exposed as a live "HUD Depth" slider; 0 keeps
          the exactly-on-panel behaviour, so the user's eyes stay the judge.
      `a` = P[0][0] of the last-seen PERSPECTIVE, latched live (FOV animates).

   b) Both eyes, every host frame (guide §2.4 "secret #1"), in gfx_run().
      The natural site is pc_main.c's gfx_start_frame/send_display_list/
      gfx_end_frame_render/gfx_display_frame block — but overlay 0007's probe
      hunk ENCLOSES that block, and editing inside another patch's hunk breaks
      apply-overlay's reverse probe (D6). gfx_run() is the equivalent seam one
      level down: it receives the display list, and its caller closes the frame.
      So gfx_run renders the LEFT eye to completion itself, then returns having
      selected the RIGHT eye — which the caller's unmodified
      gfx_end_frame_render/gfx_display_frame close. pc_main.c is not touched at
      all for this.

      Rendering the SAME `commands` twice is exactly "same game time, only the
      projection differs": patch_interpolations() has already written this
      delta's state into the display list before send_display_list, and it is
      deliberately not re-run. Alternating eyes instead would halve each eye's
      rate and put them one frame apart in time, which reads as judder.

      Cheap, verified: gfx_sdl_start_frame() is `return true;`, and on the Metal
      path swap_buffers_begin/end and finish_render are all no-ops — presentation
      lives in rapi->end_frame. A second eye costs one more encoder + draw pass.

2c. src/game/skybox.c — the background-layer markers (P1-a). skybox.c is touched
   by NO other overlay patch, so a small new hunk is D6-clean. init_skybox_
   display_list() brackets the skybox's ORTHO projection with a gDPNoOpTag pair
   carrying sentinel tags; ext_gfx_run_dl's new G_NOOP case flips a background
   flag so the ortho branch gives the skybox infinity disparity. The command
   count is bumped +2 for the two markers. All gated on SM64_VISION_3D, so
   iOS/desktop skybox.o is byte-identical. Fable's marker approach beats the
   order-heuristic fallback (which misclassifies pure-2D screens).

3. src/pc/pc_main.c — the engine main rename, via ONE macro and no edit to
   `int main`.
   The SwiftUI @main owns the process entry, so coopdx's main must become a
   plain function the hosting VC calls. Overlay 0008 inserts its
   `#include "sm64_vision_shell.h"` IMMEDIATELY above `int main` (pristine :523),
   making that line 0008's trailing context — editing it would break 0008's
   reverse probe (D6). So instead an `#undef main` / `#define main
   sm64_engine_main` is placed far away (after `void game_loop_one_iteration
   (void);`, pristine :118, clear of every existing hunk) and the `int main` line
   is left byte-identical. The #undef is load-bearing: SDL2's SDL_main.h has
   already #define'd main -> SDL_main on this target (TARGET_OS_IPHONE is 1 on
   xrOS, M-9), so without it the rename would silently not happen.

4. CMakeLists.txt — NOT TOUCHED AT ALL.
   The Swift/sources/frameworks wiring lives in app/vision3d/vision3d.cmake,
   passed by path as -DCMAKE_PROJECT_sm64coopdx_INCLUDE by both build scripts
   (the same "by path" precedent as SM64_VISIONOS_PLIST / _ASSETS, D-018).

   That is a deliberate retreat, not a shortcut. Every legal anchor after
   add_executable() is boxed in: 0005 owns link/properties/frameworks, 0007 owns
   the IOS_OBJC_FILES list, 0008 owns the EOF slot (M-26: at most ONE patch may
   ever hold it), 0009 owns the catalog swap, and 0010 — authored CONCURRENTLY
   with this patch — took the slot immediately after add_executable(). Inserting
   between any of those blocks and its trailing context splits that context and
   breaks the victim's reverse probe (D6). Competing for the last anchor would
   also have broken 0010 the next time either patch was regenerated. Using
   CMake's own extension point instead gives 0011 no CMakeLists.txt hunk and no
   ordering relationship with 0010 at all. See that file for the full reasoning.

   enable_language(Swift) + a mixed Swift/ObjC/C target under CMake's Xcode
   generator for xrOS is MEASURED, not assumed — a standalone spike built a
   SwiftUI @main + CompositorLayer + bridging header for xrsimulator through the
   exact CMAKE_PROJECT_<name>_INCLUDE + cmake_language(DEFER) mechanism before
   any of this was wired. The one real constraint it surfaced: the Swift entry
   file must NOT be named main.swift (Swift parses that name as top-level code,
   which collides with @main), hence SM64VisionApp.swift.

WHAT IS NOT TOUCHED
   The iOS target and both desktop backends compile byte-for-byte identically:
   every seam above is behind SM64_VISION_3D, which sm64_vision_3d.h derives
   from TargetConditionals (TARGET_OS_VISION) rather than a -D flag — same
   reasoning as D-009/D-013/D-014: a build-flag gate can be silently forgotten,
   and that must never be why a shipped build is missing this.
"""
import subprocess
import pathlib
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sm64coopdx"
APP = ROOT / "app/vision3d"

diffs = []


def diff_new_file(text, rel):
    """/dev/null hunk for a repo-owned new file (D-010 / overlay 0001 pattern)."""
    r = subprocess.run(["git", "-C", str(VENDOR), "ls-files", "--error-unmatch", rel],
                       capture_output=True)
    assert r.returncode != 0, f"[{rel}] already tracked upstream — 0011 must not clobber it"
    with tempfile.TemporaryDirectory() as td:
        empty = pathlib.Path(td) / "empty"
        empty.write_text("")
        new = pathlib.Path(td) / "new"
        new.write_text(text)
        r = subprocess.run(
            ["diff", "-uN", "--label", "/dev/null", "--label", f"b/{rel}",
             str(empty), str(new)], capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    return r.stdout


def diff_edit(orig, new, rel):
    with tempfile.TemporaryDirectory() as td:
        fa = pathlib.Path(td) / "a"
        fb = pathlib.Path(td) / "b"
        fa.write_text(orig)
        fb.write_text(new)
        r = subprocess.run(["diff", "-u", "--label", f"a/{rel}", "--label", f"b/{rel}",
                            str(fa), str(fb)], capture_output=True, text=True)
    assert r.returncode == 1, f"[{rel}] no diff produced"
    return r.stdout


def replace_once(text, old, new, tag, sentinel):
    """Match-count-asserted replace (charter ground rule 1) + already-applied guard.

    Every anchor below has its OLD text as a substring of its NEW text (we insert
    AROUND anchors rather than rewrite them), so `count(old) == 1` stays true even
    on an already-patched tree and the count assert alone would happily emit a
    doubled hunk. The sentinel makes the charter's reverse-then-regenerate
    workflow an enforced failure instead of a convention (0008's pattern).
    """
    assert sentinel not in text, (
        f"[{tag}] already applied (found sentinel {sentinel!r}) — "
        f"`patch -p1 -R` overlay 0011 out of vendor before regenerating")
    n = text.count(old)
    assert n == 1, f"[{tag}] expected exactly 1 match, got {n}"
    return text.replace(old, new)


# ---------------------------------------------------------------------------
# 1. The 3D shell — packaged from app/vision3d/ (the source of truth), never
#    authored here. D-010: a new file has no pristine anchor to assert against,
#    so keeping the real file real is what keeps the generator honest.
# ---------------------------------------------------------------------------
NEW_FILES = [
    "sm64_vision_3d.h",
    "sm64_vision_host.h",
    "sm64_vision_host.m",
    "sm64_immersive.m",
    "sm64_vision_settings.m",
    "sm64-bridging-header.h",
    "SM64VisionApp.swift",
    # R0 SPIKE (throwaway — VR-CHARTER §5 R0.1). Remove these two with the spike.
    "sm64_vr_spike.h",
    "sm64_vr_spike.m",
    # The in-game VR options panel (charter R2, pulled forward 2026-08-07).
    "djui_panel_vr.h",
    "djui_panel_vr.c",
    # Charter A5: the menu/gameplay predicate, read from the game's own state.
    "sm64_vr_gamestate.c",
    # Charter R2: the view modes and their remembered tunables.
    "sm64_vr_presets.c",
    # Charter R3: PSVR2 Sense controllers as an N64 pad.
    "controller_vision.h",
    "controller_vision.m",
]
for name in NEW_FILES:
    src = APP / name
    assert src.is_file(), f"missing source of truth: {src}"
    text = src.read_text()
    assert text, f"empty source: {src}"
    diffs.append(diff_new_file(text, f"src/pc/vision3d/{name}"))

# ---------------------------------------------------------------------------
# 2. gfx_pc.c — the per-eye projection + both-eyes-per-frame.
# ---------------------------------------------------------------------------
REL_GFX = "src/pc/gfx/gfx_pc.c"
orig_gfx = (VENDOR / REL_GFX).read_text()

OLD_STEREO = "static void OPTIMIZE_O3 gfx_sp_matrix(uint8_t parameters, const int32_t *addr) {"
NEW_STEREO = '''// ---------------------------------------------------------------------------
// visionOS stereoscopic 3D — the per-eye projection (overlay 0011, Phase 2).
//
// Self-gating on TargetConditionals rather than a -D flag (D-013/D-014's
// reasoning), so the iOS target and both desktop backends compile this file to
// byte-identical code: GFX_PROJECTION() degenerates to rsp.P_matrix.
// ---------------------------------------------------------------------------
#include "pc/vision3d/sm64_vision_3d.h"

#ifdef SM64_VISION_3D
// The eye currently being rendered. ONE source of truth: gfx_metal.mm reads
// this to pick the matching render target, so the projection and the texture it
// lands in can never disagree about which eye is in flight.
int sm64_gfx_3d_eye = SM64_EYE_OFF;

// Retuned defaults. sep 9.0 = a modest hyper-stereo for a MINIATURE world (real
// volume + two-sided slider travel). conv 1524 (~50 ft) — comfort batch 2 item 6:
// device feedback preferred 50 ft over the old 800 (~26 ft). These are only the
// never-touched fallback; the settings sheet pushes the persisted values (and the
// convAuto-derived convergence) over them on entry, and Reset returns here.
static float sm64_gfx_3d_sep = 9.0f;
static float sm64_gfx_3d_conv = 1524.0f;

// HUD depth (P1-b): how far in FRONT of the panel the ORTHO UI layer floats.
// Comfort batch 2 item 5: DEFAULT is now 0 (flush on panel = original) and the
// slider was removed — the effect only reached the ortho HUD (health + Mario
// head), not the Lakitu dialog boxes (a separate draw path), so it did not fix
// the dialog-foreground complaint. The plumbing stays but is always fed 0.
static float sm64_gfx_3d_hud = 0.0f;

// Background-layer flag (P1-a): SET/CLEARED by the skybox's gDPNoOpTag markers
// (skybox.c) through the G_NOOP case in ext_gfx_run_dl below. While set, the
// ortho branch gives the layer far-plane (infinity) disparity so the backdrop
// sits BEHIND the world instead of on the panel in front of it.
static int sm64_gfx_bg_layer = 0;

// P[0][0] of the last-seen PERSPECTIVE projection, latched live because SM64's
// FOV animates (don't hard-code it). The ortho disparity math needs this scale,
// and the skybox ortho is loaded before the frame's perspective, so the latch is
// carried across frames. Seeded with a typical SM64 value until one is seen.
static float sm64_gfx_persp_a = 1.30f;

void sm64_gfx_set_3d_eye(int eye) {
    sm64_gfx_3d_eye = (eye >= SM64_EYE_OFF && eye <= SM64_EYE_RIGHT) ? eye : SM64_EYE_OFF;
}

void sm64_gfx_set_3d_params(float separation, float convergence, float hud_depth) {
    if (separation >= 0.0f && separation <= 60.0f) { sm64_gfx_3d_sep = separation; } // clamp raised 40->60 for the 2026-07-23 depth rescale (new slider max 54)
    if (convergence >= 50.0f && convergence <= 8000.0f) { sm64_gfx_3d_conv = convergence; }
    if (hud_depth >= 0.0f && hud_depth <= 3.0f) { sm64_gfx_3d_hud = hud_depth; }
}

static Mat4 sm64_gfx_eye_P;

// R0 SPIKE (throwaway — VR-CHARTER §5 R0.2 / A3). The VR path replaces the
// projection outright with the composed camera-space -> eye-clip matrix
// (EyeVP = A * V * P) the compositor loop publishes, instead of skewing the
// game's own projection the way the panel's stereo does. Returns NULL whenever
// VR is not driving, so the panel path below is byte-for-byte unchanged.
const float *sm64_vr_eye_viewproj(int eye);   // sm64_vr_spike.m
int          sm64_vr_hide_background(void);   // 1 = drop the ortho skybox
const float *sm64_vr_hud_matrix(int eye);     // ortho -> head-locked plane -> eye clip

// The projection to compose into MP for the eye currently in flight.
static float (*gfx_stereo_projection(void))[4] {
    if (sm64_gfx_3d_eye == SM64_EYE_OFF) { return rsp.P_matrix; }

    // R0 SPIKE: VR override. Perspective geometry takes the published EyeVP;
    // the ORTHO layer has no meaningful place in a surrounding world yet, so the
    // background (SM64's skybox is a FULLSCREEN ortho image, not a dome) is
    // pushed outside the frustum and clipped away — otherwise it papers over the
    // whole view and there is nothing to see the world hang in. The HUD/menu
    // ortho is left alone so there is a familiar reference in frame.
    {
        const float *vrm = sm64_vr_eye_viewproj(sm64_gfx_3d_eye);
        if (vrm != NULL) {
            if (rsp.P_matrix[3][3] > 0.5f) {
                if (sm64_gfx_bg_layer && sm64_vr_hide_background()) {
                    mtxf_copy(sm64_gfx_eye_P, rsp.P_matrix);
                    sm64_gfx_eye_P[3][0] += 10.0f; // ortho w == 1 => NDC x ~ +10, fully clipped
                    return sm64_gfx_eye_P;
                }
                // HUD / menus (charter A6). Passing the game's ortho through
                // UNCHANGED gives the 2D layer zero disparity in TEXTURE space,
                // which on canted VR optics is a ~0.54 NDC ANGULAR split — a
                // massively doubled HUD (measured on device 2026-08-07 from the
                // eye dumps). Compose the game's ortho onto a HEAD-LOCKED plane
                // instead, so both eyes place it at one real distance.
                const float *hud = sm64_vr_hud_matrix(sm64_gfx_3d_eye);
                if (hud != NULL) {
                    mtxf_mul(sm64_gfx_eye_P, rsp.P_matrix, (float (*)[4])hud);
                    return sm64_gfx_eye_P;
                }
                return rsp.P_matrix;
            }
            memcpy(sm64_gfx_eye_P, vrm, sizeof(sm64_gfx_eye_P));
            return sm64_gfx_eye_P;
        }
    }

    // Signed half-separation for this eye.
    const float e = (sm64_gfx_3d_eye == SM64_EYE_RIGHT ? 1.0f : -1.0f) * 0.5f * sm64_gfx_3d_sep;

    // ORTHO vs PERSPECTIVE — the tree's OWN predicate (gfx_adjust_x_for_aspect_
    // ratio uses the identical test). SM64's 2D layer is all ortho; its 3D world
    // is all perspective.
    if (rsp.P_matrix[3][3] > 0.5f) {
        // --- ORTHO branch (P1-a skybox / P1-b HUD) --------------------------
        // An ortho layer has constant clip.w, so a constant added to clip.x is a
        // constant NDC-x SHIFT — a fixed per-eye disparity. The ortho-not-offset
        // rule used to put ALL ortho on the panel (disparity 0); but the skybox
        // belongs at infinity and the UI belongs slightly in front:
        //
        //   shift(d) = a*e*(1/C - 1/d)     (a = last perspective P[0][0])
        //     d = C   -> 0        (on panel; still the case for hud == 0)
        //     d = inf -> a*e/C    (the disparity of infinity — never divergent)
        //     d < C   -> crossed  (in front of the panel)
        //
        // skybox/background -> d = inf: sits BEHIND the mountains painted in it,
        //   killing the "clouds in front of the world" contradiction (P1-a).
        // HUD/dialog/menus  -> d_ui = C/(1+hud) => shift = -hud*a*e/C, a small
        //   CROSSED disparity so the UI floats in FRONT and beats popped-out
        //   geometry (P1-b). hud == 0 keeps today's exactly-on-panel behaviour.
        const float d_inf = sm64_gfx_persp_a * e / sm64_gfx_3d_conv;
        float shift;
        if (sm64_gfx_bg_layer) {
            shift = d_inf;
        } else if (sm64_gfx_3d_hud > 0.0001f) {
            shift = -sm64_gfx_3d_hud * d_inf;
        } else {
            return rsp.P_matrix; // on-panel (HUD depth disabled)
        }
        mtxf_copy(sm64_gfx_eye_P, rsp.P_matrix);
        // Row 3 is the clip-space translation row (the vertex loop reads MP[3][0]
        // as the constant term of clip.x — the same convention the eye offset
        // below uses). w is constant for ortho, so this is a pure NDC-x shift.
        sm64_gfx_eye_P[3][0] += shift;
        return sm64_gfx_eye_P;
    }

    // --- PERSPECTIVE branch -------------------------------------------------
    // Latch a = P[0][0] for the ortho branch (FOV animates, so track it live).
    sm64_gfx_persp_a = rsp.P_matrix[0][0];

    mtxf_copy(sm64_gfx_eye_P, rsp.P_matrix);

    // 1. Eye offset, folded into the projection. gfx_pc has no separate view
    //    matrix (the game bakes view*model into the modelview stack), but a
    //    view-space translation T can be folded into P: vertices compute
    //    v * MV * P, so v * MV * T * P == v * MV * (T*P). With T[3][0] = -e,
    //    (T*P) differs from P only in row 3.
    for (int i = 0; i < 4; i++) {
        sm64_gfx_eye_P[3][i] = rsp.P_matrix[3][i] - e * rsp.P_matrix[0][i];
    }

    // 2. Off-axis convergence skew — THE line that makes this fusible, and the
    //    one a sibling port got catastrophically wrong. WITHOUT it the eyes are
    //    parallel, zero parallax sits at INFINITY, the whole world floats in
    //    front of the panel with unbounded disparity, and near geometry exceeds
    //    what the eyes can fuse: it visibly jumps between two positions
    //    (binocular rivalry). WITH it, parallax is zero at exactly
    //    sm64_gfx_3d_conv — that geometry lands ON the panel, nearer pops out,
    //    farther recedes.
    //
    //    Check the algebra at the convergence plane: with a = P[0][0],
    //    clip.x = a*(x - z*e/C - e) and clip.w = -z, so at z = -C the NDC x is
    //    a*x/C — independent of e. Zero parallax, as intended.
    sm64_gfx_eye_P[2][0] += -rsp.P_matrix[0][0] * e / sm64_gfx_3d_conv;

    return sm64_gfx_eye_P;
}
#define GFX_PROJECTION() gfx_stereo_projection()
#else
#define GFX_PROJECTION() rsp.P_matrix
#endif

static void OPTIMIZE_O3 gfx_sp_matrix(uint8_t parameters, const int32_t *addr) {'''
t_gfx = replace_once(orig_gfx, OLD_STEREO, NEW_STEREO, "gfx-stereo-block",
                     "gfx_stereo_projection")

# The two MP composition sites. Distinguished by indentation (4 vs 16 spaces),
# which is why each is matched with its surrounding line rather than alone.
OLD_MP1 = """    mtxf_mul(rsp.MP_matrix, rsp.modelview_matrix_stack[rsp.modelview_matrix_stack_size - 1], rsp.P_matrix);
}

static void gfx_sp_pop_matrix(uint32_t count) {"""
NEW_MP1 = """    mtxf_mul(rsp.MP_matrix, rsp.modelview_matrix_stack[rsp.modelview_matrix_stack_size - 1], GFX_PROJECTION());
}

static void gfx_sp_pop_matrix(uint32_t count) {"""
t_gfx = replace_once(t_gfx, OLD_MP1, NEW_MP1, "mp-compose-push", "GFX_PROJECTION());\n}")

OLD_MP2 = """                mtxf_mul(rsp.MP_matrix, rsp.modelview_matrix_stack[rsp.modelview_matrix_stack_size - 1], rsp.P_matrix);"""
NEW_MP2 = """                mtxf_mul(rsp.MP_matrix, rsp.modelview_matrix_stack[rsp.modelview_matrix_stack_size - 1], GFX_PROJECTION());"""
t_gfx = replace_once(t_gfx, OLD_MP2, NEW_MP2, "mp-compose-pop",
                     "                mtxf_mul(rsp.MP_matrix, rsp.modelview_matrix_stack[rsp.modelview_matrix_stack_size - 1], GFX_PROJECTION());")

OLD_RUN = """void gfx_run(Gfx *commands) {
    gfx_sp_reset();"""
NEW_RUN = """void gfx_run(Gfx *commands) {
#ifdef SM64_VISION_3D
    // BOTH EYES, EVERY HOST FRAME (guide §2.4, "secret #1" — this is why
    // vkQuake feels buttery). The naive alternative alternates eyes, which
    // halves each eye's rate AND puts the two eyes one frame apart in time; the
    // visual system reads that temporal disparity as judder while moving.
    //
    // Render the LEFT eye to completion right here, then fall through having
    // selected the RIGHT eye — the caller's UNMODIFIED gfx_end_frame_render() /
    // gfx_display_frame() close it. That is why this lives in gfx_run() and not
    // at the obvious site in pc_main.c: overlay 0007's probe hunk encloses that
    // block, and editing inside another patch's hunk breaks the reverse probe (D6).
    //
    // Same `commands`, same game time, only the projection differs:
    // patch_interpolations() already wrote this delta's state into the display
    // list before send_display_list, and re-running it is neither needed nor
    // wanted. Cheap: gfx_sdl_start_frame() is `return true;` and on the Metal
    // path swap_buffers_begin/end and finish_render are all no-ops.
    // Main-thread per-frame hook. gfx_run() is called from the game loop, which
    // OWNS the main thread (docs/frame-map.md:111) — so this IS the main thread
    // and the shell can touch UIKit here directly, with no dispatch. That is not
    // a convenience: the main dispatch queue is not a reliable channel while the
    // loop never returns to the run loop (D-024 / M-38), so "after boot" work
    // has nowhere else to live.
    sm64_3d_frame_poll();
    if (sm64_metal_get_3d_mode()) {
        sm64_gfx_set_3d_eye(SM64_EYE_LEFT);
        gfx_run_eye(commands);
        gfx_end_frame_render();
        gfx_display_frame();
        sm64_gfx_set_3d_eye(SM64_EYE_RIGHT);
    }
    gfx_run_eye(commands);
}

static void gfx_run_eye(Gfx *commands) {
#endif
    gfx_sp_reset();"""
t_gfx = replace_once(t_gfx, OLD_RUN, NEW_RUN, "gfx-run-both-eyes", "gfx_run_eye")

# gfx_run_eye is called by gfx_run() before its own definition (they are one
# function split in two). gfx_end_frame_render/gfx_display_frame need no
# forward declaration — gfx_pc.h:43-44 already declares them and this file
# includes it at :37.
OLD_FWD = """void gfx_start_frame(void) {"""
NEW_FWD = """#ifdef SM64_VISION_3D
// The tail of gfx_run(), split out so the both-eyes path can run it twice.
static void gfx_run_eye(Gfx *commands);
#endif

void gfx_start_frame(void) {"""
t_gfx = replace_once(t_gfx, OLD_FWD, NEW_FWD, "gfx-run-eye-fwd", "static void gfx_run_eye(Gfx *commands);")

# P1-a: the G_NOOP handler that reads the skybox's background-layer markers.
# G_NOOP already routes to ext_gfx_run_dl via gfx_run_dl's default case, and ext
# currently has no case for it (a true no-op), so this is a pure add. The anchor
# is ext_gfx_run_dl's full signature (the bare `switch (opcode) {` is NOT unique —
# gfx_run_dl has one too).
OLD_EXT = """void OPTIMIZE_O3 ext_gfx_run_dl(Gfx* cmd) {
    uint32_t opcode = cmd->words.w0 >> 24;
    switch (opcode) {"""
NEW_EXT = """void OPTIMIZE_O3 ext_gfx_run_dl(Gfx* cmd) {
    uint32_t opcode = cmd->words.w0 >> 24;
    switch (opcode) {
#ifdef SM64_VISION_3D
        // visionOS stereo P1-a: init_skybox_display_list() (skybox.c) brackets
        // the skybox's ortho projection with gDPNoOpTag markers so
        // gfx_stereo_projection() can give the backdrop far-plane disparity
        // instead of on-panel zero. A plain gDPNoOp (tag 0) or any non-sentinel
        // tag falls through this case untouched.
        case G_NOOP:
            if ((uint32_t)cmd->words.w1 == SM64_GFX_TAG_BG_BEGIN) { sm64_gfx_bg_layer = 1; }
            else if ((uint32_t)cmd->words.w1 == SM64_GFX_TAG_BG_END) { sm64_gfx_bg_layer = 0; }
            break;
#endif"""
t_gfx = replace_once(t_gfx, OLD_EXT, NEW_EXT, "ext-noop-bg", "SM64_GFX_TAG_BG_BEGIN")

# P1-a defensive reset: clear the background flag at the start of every eye's
# display-list run, so a torn display list can never leave the HUD misclassified.
OLD_RESET = """static void gfx_sp_reset(void) {
    rsp.modelview_matrix_stack_size = 1;"""
NEW_RESET = """static void gfx_sp_reset(void) {
#ifdef SM64_VISION_3D
    // P1-a defensive reset: each eye's display-list run starts with no background
    // layer active. The skybox sets it via its gDPNoOpTag begin marker and clears
    // it with the end marker; this guards the HUD if a list is torn off early.
    sm64_gfx_bg_layer = 0;
#endif
    rsp.modelview_matrix_stack_size = 1;"""
t_gfx = replace_once(t_gfx, OLD_RESET, NEW_RESET, "gfx-sp-reset-bg", "P1-a defensive reset")

# Comfort batch 2 item 2 (panel reshape). In 3D the game must render at the
# PANEL's aspect so the image FILLS a reshaped panel with no letterbox — but
# gfx_current_dimensions (which drives the FOV aspect via x_adjust_ratio and the
# default viewport) is set from the WINDOW's drawable, which is only the parked
# control card. Override it here, at the frame boundary (no mid-frame framebuffer
# race — the charter black-screen warning), with the panel-aspect eye-texture
# target. gfx_metal sizes the offscreen eye texture from the SAME function
# (sm64_3d_get_render_target_size), so FOV, viewport and texture can never
# disagree. Both are on the main thread within one host frame, so the read is
# stable across both eyes. 2D and iOS/desktop are untouched (mode gate + #ifdef).
OLD_DIMS = """    gfx_wapi->get_dimensions(&gfx_current_dimensions.width, &gfx_current_dimensions.height);
    if (gfx_current_dimensions.height == 0) {"""
NEW_DIMS = """    gfx_wapi->get_dimensions(&gfx_current_dimensions.width, &gfx_current_dimensions.height);
#ifdef SM64_VISION_3D
    // Comfort batch 2 item 2 (panel reshape): render at the PANEL's aspect, not
    // the parked control window's, so the image FILLS a reshaped panel undistorted
    // (no letterbox bars). sm64_3d_get_render_target_size is the SAME source
    // gfx_metal sizes the offscreen eye texture from, so FOV + viewport + texture
    // agree. Applied at the frame boundary => no mid-frame framebuffer race.
    if (sm64_metal_get_3d_mode()) {
        int sm64_vw = 0, sm64_vh = 0;
        sm64_3d_get_render_target_size(&sm64_vw, &sm64_vh);
        if (sm64_vw > 0 && sm64_vh > 0) {
            gfx_current_dimensions.width = (uint32_t) sm64_vw;
            gfx_current_dimensions.height = (uint32_t) sm64_vh;
        }
    }
#endif
    if (gfx_current_dimensions.height == 0) {"""
# ---------------------------------------------------------------------------
# 2d. gfx_adjust_x_for_aspect_ratio — DO NOT squeeze x in VR.
#
# THE CAUSE OF THE DOUBLED VR VIEW, measured on device 2026-08-07. This function
# multiplies EVERY vertex's clip.x by (4/3)/aspect so a 4:3-designed game fills a
# widescreen target: 0.75 on our 16:9 eye render. On the flat 3D panel that is
# both correct and harmless (identical for both eyes). In VR the projection is
# the COMPOSITOR's own per-eye frustum, and Vision Pro cants those frusta ~36
# degrees apart, so a 0.75x on clip.x compresses each eye toward its OWN centre
# and leaves the two images angularly wrong by a large constant in OPPOSITE
# directions — double vision that the stereo slider barely moves, because the
# error is not parallax at all.
#
# Proof, not inference: the published matrices predict 0.555 NDC of disparity at
# the castle and 0.582 near; the dumped eye images measure 0.430 and 0.465, a
# 0.78x ratio. Pristine territory — no other overlay hunk touches this function.
OLD_ASPECT = """static float gfx_adjust_x_for_aspect_ratio(float x) {
    float adjusted = x * gfx_current_dimensions.x_adjust_ratio;"""
NEW_ASPECT = """static float gfx_adjust_x_for_aspect_ratio(float x) {
#ifdef SM64_VISION_3D
    // VR: the projection IS the compositor's per-eye frustum, so ANY extra
    // horizontal scaling breaks the NDC->direction mapping its optics assume.
    // See gen-patch-0011.py section 2d for the device measurement.
    if (sm64_vr_eye_viewproj(sm64_gfx_3d_eye) != NULL) { return x; }
#endif
    float adjusted = x * gfx_current_dimensions.x_adjust_ratio;"""
t_gfx = replace_once(t_gfx, OLD_ASPECT, NEW_ASPECT, "gfx-aspect-vr-bypass",
                     "gen-patch-0011.py section 2d")

t_gfx = replace_once(t_gfx, OLD_DIMS, NEW_DIMS, "gfx-start-frame-panel-aspect",
                     "sm64_3d_get_render_target_size(&sm64_vw, &sm64_vh)")

diffs.append(diff_edit(orig_gfx, t_gfx, REL_GFX))

# ---------------------------------------------------------------------------
# 2h. first_person_cam.c — yaw-only stick look in VR (charter R4).
#
# The donor's FIRST public player request, and they were right: in VR the headset
# owns pitch, and a stick that also pitches fights it for control of where you
# are looking. Charter R4 adopts it as the FP default.
#
# The fix lands at the CONSUMING FOLD, which is the donor's hard-won rule
# (ledger: "the source ships RAW signs; each mode's fold owns its own feel; fix
# the fold of the mode that feels wrong, NEVER the shared source"). Zeroing the
# stick anywhere shared would break third-person's camera too. Pristine file, and
# gated twice — on SM64_VISION_3D and on the setting — so nothing changes for
# anyone not in VR first-person.
REL_FPC = "src/game/first_person_cam.c"
orig_fpc = (VENDOR / REL_FPC).read_text()

OLD_FPC_INC = '#include "first_person_cam.h"'
NEW_FPC_INC = ('#include "first_person_cam.h"\n'
               '#include "pc/vision3d/sm64_vision_3d.h"')
t_fpc = replace_once(orig_fpc, OLD_FPC_INC, NEW_FPC_INC, "fpc-vision-include",
                     "pc/vision3d/sm64_vision_3d.h")

OLD_FPC_PITCH = """        // update pitch
        if (!gFirstPersonCamera.forcePitch) {
            gFirstPersonCamera.pitch -= sensY * (extStickY - 1.5f * mouse_y);
            gFirstPersonCamera.pitch = clamp(gFirstPersonCamera.pitch, -0x3F00, 0x3F00);
        }

        // update yaw
        if (!gFirstPersonCamera.forceYaw) {
            if (m->controller->buttonDown & L_TRIG && gFirstPersonCamera.centerL) {
                gFirstPersonCamera.yaw = m->faceAngle[1] + 0x8000;
            } else {
                gFirstPersonCamera.yaw += sensX * (extStickX - 1.5f * mouse_x);
            }
        }"""
NEW_FPC_PITCH = """        // update pitch
#ifdef SM64_VISION_3D
        // VR first-person owns this fold. Three things happen here and nowhere
        // else, which is the donor's rule: the source ships raw signs and each
        // mode's fold owns its own feel, so touching anything shared would break
        // third-person's camera instead.
        //   1. The X sign is INVERTED. First-person and third-person consume the
        //      same ext_stick with opposite conventions, and in VR first-person
        //      the stick turned the wrong way (Austin, 2026-08-08).
        //   2. Look mode: Free pitches with the stick as normal; Turn and Snap
        //      leave pitch to the headset, which already owns it.
        //   3. Snap is an instant 45 degrees per flick, re-armed when the stick
        //      returns to centre — the discrete turn other VR games use.
        int sm64VrLook = sm64_vr_stick_look_mode();   // -1 when this is not VR first-person
        if (sm64VrLook >= 0) {
            extStickX = -extStickX;
            sensX *= sm64_vr_look_sensitivity();
            sensY *= sm64_vr_look_sensitivity();
            if (sm64VrLook != 0) { extStickY = 0.0f; mouse_y = 0; }
        }
#endif
        if (!gFirstPersonCamera.forcePitch) {
            gFirstPersonCamera.pitch -= sensY * (extStickY - 1.5f * mouse_y);
            gFirstPersonCamera.pitch = clamp(gFirstPersonCamera.pitch, -0x3F00, 0x3F00);
        }

        // update yaw
        if (!gFirstPersonCamera.forceYaw) {
            if (m->controller->buttonDown & L_TRIG && gFirstPersonCamera.centerL) {
                gFirstPersonCamera.yaw = m->faceAngle[1] + 0x8000;
            } else {
#ifdef SM64_VISION_3D
            if (sm64VrLook == 2) {
                static bool sm64VrSnapArmed = true;
                if (sm64VrSnapArmed && (extStickX > 12.0f || extStickX < -12.0f)) {
                    gFirstPersonCamera.yaw += (extStickX > 0.0f) ? 0x2000 : -0x2000; // 45 deg
                    sm64VrSnapArmed = false;
                } else if (extStickX < 5.0f && extStickX > -5.0f) {
                    sm64VrSnapArmed = true;
                }
            } else
#endif
                gFirstPersonCamera.yaw += sensX * (extStickX - 1.5f * mouse_x);
            }
        }"""
t_fpc = replace_once(t_fpc, OLD_FPC_PITCH, NEW_FPC_PITCH, "fpc-vr-look",
                     "sm64_vr_stick_look_mode")

diffs.append(diff_edit(orig_fpc, t_fpc, REL_FPC))

# ---------------------------------------------------------------------------
# 2g. controller_entry_point.c — register the Sense backend beside SDL.
#
# Charter A10, and the donor's own precedent: their VR backend sits beside
# sdl/touchscreen rather than replacing anything, because both may be connected
# at once and both feed one pad. Pristine file — no other overlay touches it —
# and the backend self-gates, so iOS and desktop are unchanged.
REL_CTRL = "src/pc/controller/controller_entry_point.c"
orig_ctrl = (VENDOR / REL_CTRL).read_text()

OLD_CTRL_INC = '#include "controller_sdl.h"'
NEW_CTRL_INC = ('#include "controller_sdl.h"\n'
                '#include "pc/vision3d/controller_vision.h"')
t_ctrl = replace_once(orig_ctrl, OLD_CTRL_INC, NEW_CTRL_INC, "ctrl-vision-include",
                      "pc/vision3d/controller_vision.h")

OLD_CTRL_LIST = """static struct ControllerAPI *controller_implementations[] = {
    &controller_sdl,"""
NEW_CTRL_LIST = """static struct ControllerAPI *controller_implementations[] = {
    &controller_sdl,
#ifdef SM64_VISION_3D
    &controller_vision,   // PSVR2 Sense: a FIXED layout, deliberately not bound
#endif"""
t_ctrl = replace_once(t_ctrl, OLD_CTRL_LIST, NEW_CTRL_LIST, "ctrl-vision-register",
                      "&controller_vision")

diffs.append(diff_edit(orig_ctrl, t_ctrl, REL_CTRL))

# ---------------------------------------------------------------------------
# 2f. star_select.c — stamp the act/star selector for the VR panel routing.
#
# Charter A5's hybrid case: the selector draws 3D star models behind 2D text, so
# no "did perspective happen" heuristic classifies it, and in the stereo world it
# looks wrong (Austin, 2026-08-08). The donor added a game-side flag for exactly
# this. A few frames of grace per update also covers the moment either side of
# the load where the selector is still on screen. Pristine file, gated so iOS and
# desktop are unchanged.
REL_STAR = "src/menu/star_select.c"
orig_star = (VENDOR / REL_STAR).read_text()

OLD_STAR_INC = '#include "star_select.h"'
NEW_STAR_INC = ('#include "star_select.h"\n'
                '#include "pc/vision3d/sm64_vision_3d.h"')
t_star = replace_once(orig_star, OLD_STAR_INC, NEW_STAR_INC, "star-select-include",
                      "pc/vision3d/sm64_vision_3d.h")

OLD_STAR_UPD = "s32 lvl_update_obj_and_load_act_button_actions(UNUSED s32 arg, UNUSED s32 unused) {"
NEW_STAR_UPD = ('s32 lvl_update_obj_and_load_act_button_actions(UNUSED s32 arg, UNUSED s32 unused) {\n'
                '#ifdef SM64_VISION_3D\n'
                '    // visionOS VR: present this screen flat, like every other menu. A\n'
                '    // DEADLINE, not a frame count: this runs at the sim rate and the VR\n'
                '    // side reads it at the render rate, and counting let the two race.\n'
                '    {\n'
                '        extern double gVrActSelectorUntil;\n'
                '        extern f64 clock_elapsed_f64(void);\n'
                '        gVrActSelectorUntil = clock_elapsed_f64() + 0.25;\n'
                '    }\n'
                '#endif')
t_star = replace_once(orig_star, OLD_STAR_UPD, NEW_STAR_UPD, "star-select-stamp",
                      "gVrActSelectorFrames") if False else replace_once(
                      t_star, OLD_STAR_UPD, NEW_STAR_UPD, "star-select-stamp",
                      "gVrActSelectorUntil = clock_elapsed_f64()")

diffs.append(diff_edit(orig_star, t_star, REL_STAR))

# ---------------------------------------------------------------------------
# 2e. djui_panel_options.c — one button for the in-game VR panel.
#
# Pristine territory: no other overlay hunk touches this file. The panel itself
# is repo-owned (packaged above) and self-gates on SM64_VISION_3D, so iOS and
# desktop compile this file to the same bytes as before.
REL_OPT = "src/pc/djui/djui_panel_options.c"
orig_opt = (VENDOR / REL_OPT).read_text()

OLD_OPT_INC = '#include "djui_panel_dynos.h"'
NEW_OPT_INC = ('#include "djui_panel_dynos.h"\n'
               '// visionOS VR options (overlay 0011). The header self-gates, so this include\n'
               '// costs nothing on any other platform.\n'
               '#include "pc/vision3d/djui_panel_vr.h"')
t_opt = replace_once(orig_opt, OLD_OPT_INC, NEW_OPT_INC, "options-vr-include",
                     "pc/vision3d/djui_panel_vr.h")

OLD_OPT_BTN = '        djui_button_create(body, DLANG(OPTIONS, DISPLAY), DJUI_BUTTON_STYLE_NORMAL, djui_panel_display_create);'
NEW_OPT_BTN = ('        djui_button_create(body, DLANG(OPTIONS, DISPLAY), DJUI_BUTTON_STYLE_NORMAL, djui_panel_display_create);\n'
               '#ifdef SM64_VISION_3D\n'
               '        // Next to Display, because that is what it is: how the game is presented.\n'
               '        djui_button_create(body, "VR", DJUI_BUTTON_STYLE_NORMAL, djui_panel_vr_create);\n'
               '#endif')
t_opt = replace_once(t_opt, OLD_OPT_BTN, NEW_OPT_BTN, "options-vr-button",
                     'djui_panel_vr_create')

diffs.append(diff_edit(orig_opt, t_opt, REL_OPT))

# ---------------------------------------------------------------------------
# 2b. skybox.c — the background-layer markers (P1-a). skybox.c is touched by NO
#     other overlay patch, so a small new hunk is D6-clean (Fable's plan). Every
#     addition is gated on SM64_VISION_3D so iOS/desktop skybox.o is unaffected.
# ---------------------------------------------------------------------------
REL_SKY = "src/game/skybox.c"
orig_sky = (VENDOR / REL_SKY).read_text()

# The vision header (ungated, like gfx_pc.c/pc_main.c — it compiles to nothing on
# non-vision). It provides SM64_VISION_3D and the shared tag sentinels.
OLD_SKY_INC = '#include "skybox.h"'
NEW_SKY_INC = ('#include "skybox.h"\n'
               '\n'
               '// visionOS stereo (overlay 0011, P1-a): SM64\'s skybox is ORTHO, so the\n'
               '// ortho-not-offset gate would leave it at zero disparity = on the panel,\n'
               '// stereoscopically in FRONT of the world painted behind it. Bracket the\n'
               '// skybox ortho draw with gDPNoOpTag markers so gfx_pc.c can give the\n'
               '// backdrop far-plane disparity instead. All gated so iOS/desktop unaffected.\n'
               '#include "pc/vision3d/sm64_vision_3d.h"')
t_sky = replace_once(orig_sky, OLD_SKY_INC, NEW_SKY_INC, "skybox-include",
                     'pc/vision3d/sm64_vision_3d.h')

# +2 display-list commands need +2 allocation, or the buffer overruns.
OLD_SKY_COUNT = ('    s32 dlCommandCount = 5 + (sSkyboxTileNumY * sSkyboxTileNumX) * 8;'
                 ' // 5 for the start and end, plus the amount of skybox tiles')
NEW_SKY_COUNT = ('#ifdef SM64_VISION_3D\n'
                 '    s32 dlCommandCount = 7 + (sSkyboxTileNumY * sSkyboxTileNumX) * 8;'
                 ' // +2 for the P1-a background markers\n'
                 '#else\n'
                 '    s32 dlCommandCount = 5 + (sSkyboxTileNumY * sSkyboxTileNumX) * 8;'
                 ' // 5 for the start and end, plus the amount of skybox tiles\n'
                 '#endif')
t_sky = replace_once(t_sky, OLD_SKY_COUNT, NEW_SKY_COUNT, "skybox-count",
                     "+2 for the P1-a background markers")

# The markers themselves: BEGIN before the ortho matrix load (so the flag is set
# when gfx_stereo_projection composes the skybox MP), END after the tile grid.
OLD_SKY_DL = """        gSPDisplayList(dlist++, dl_skybox_begin);
        gSPMatrix(dlist++, VIRTUAL_TO_PHYSICAL(ortho), G_MTX_PROJECTION | G_MTX_MUL | G_MTX_NOPUSH);
        gSPDisplayList(dlist++, dl_skybox_tile_tex_settings);
        draw_skybox_tile_grid(&dlist, background, player, colorIndex);
        gSPDisplayList(dlist++, dl_skybox_end);"""
NEW_SKY_DL = """        gSPDisplayList(dlist++, dl_skybox_begin);
#ifdef SM64_VISION_3D
        gDPNoOpTag(dlist++, SM64_GFX_TAG_BG_BEGIN); // P1-a: mark the background ortho
#endif
        gSPMatrix(dlist++, VIRTUAL_TO_PHYSICAL(ortho), G_MTX_PROJECTION | G_MTX_MUL | G_MTX_NOPUSH);
        gSPDisplayList(dlist++, dl_skybox_tile_tex_settings);
        draw_skybox_tile_grid(&dlist, background, player, colorIndex);
#ifdef SM64_VISION_3D
        gDPNoOpTag(dlist++, SM64_GFX_TAG_BG_END); // P1-a: end the background ortho
#endif
        gSPDisplayList(dlist++, dl_skybox_end);"""
t_sky = replace_once(t_sky, OLD_SKY_DL, NEW_SKY_DL, "skybox-markers", "SM64_GFX_TAG_BG_BEGIN")

diffs.append(diff_edit(orig_sky, t_sky, REL_SKY))

# ---------------------------------------------------------------------------
# 3. pc_main.c — the engine main rename, WITHOUT touching `int main`.
# ---------------------------------------------------------------------------
REL_MAIN = "src/pc/pc_main.c"
orig_main = (VENDOR / REL_MAIN).read_text()

OLD_RENAME = """void game_loop_one_iteration(void);"""
NEW_RENAME = """void game_loop_one_iteration(void);

// ---------------------------------------------------------------------------
// visionOS: the SwiftUI @main owns the process entry (overlay 0011, Phase 2).
//
// An ImmersiveSpace can only be declared from a SwiftUI App, so SDL's
// UIApplicationMain wrapper is bypassed and coopdx's main() becomes a plain
// function that SM64HostViewController calls after SDL_SetMainReady().
//
// Done as a macro, HERE, rather than by editing the `int main` line ~400 lines
// below: overlay 0008 inserts its #include immediately above that line, making
// it 0008's trailing context, and editing inside another patch's hunk breaks
// apply-overlay's reverse probe (charter D6). This spot is clear of every
// existing hunk.
//
// The #undef is LOAD-BEARING, not hygiene: SDL2's SDL_main.h has already
// #define'd main -> SDL_main on this target (it keys off __IPHONEOS__, and
// TARGET_OS_IPHONE is 1 on xrOS — M-9). Without the #undef the rename would
// silently not happen and the SwiftUI entry would never call the engine.
// ---------------------------------------------------------------------------
#include "pc/vision3d/sm64_vision_3d.h"
#ifdef SM64_VISION_3D
#undef main
#define main sm64_engine_main
#endif"""
t_main = replace_once(orig_main, OLD_RENAME, NEW_RENAME, "main-rename",
                      "#define main sm64_engine_main")

diffs.append(diff_edit(orig_main, t_main, REL_MAIN))

# ---------------------------------------------------------------------------
out = ROOT / "overlay/patches/0011-visionos-stereo3d.patch"
out.write_text(__doc__ + "\n" + "".join(diffs))
print(f"wrote {out} ({len(diffs)} file diffs)")
