// sm64_vr_gamestate.c — "is this frame a menu?", answered from the game's own
// state machine (charter A5, ported from the donor's vr_frame_is_nongameplay,
// pc_main.c:274-305).
//
// WHY IT IS KEYED ON GAME STATE AND NOT ON WHAT GOT DRAWN. Screens like the
// act/star selector render 3D models behind 2D text, so "did a perspective
// matrix appear this frame" misclassifies them. The donor learned that one the
// hard way; asking the state machine is robust for the hybrids.
//
// TRUE  -> present the whole flat frame on a world-locked panel, the way the
//          existing 3D mode already looks. Menus, the title screen, the pause
//          grid and level transitions all become a finished flat screen instead
//          of a 2D layer floating inside a world that is not being played.
// FALSE -> active gameplay: the stereo world.
//
// Plain C, living with the VR layer rather than in vendor code, and evaluated on
// the ENGINE thread (from the frame poll) — the compositor thread must never
// read game state.

#include "pc/vision3d/sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#include <stdbool.h>

#include "pc/djui/djui.h"          // gDjuiInMainMenu
#include "pc/djui/djui_panel.h"    // djui_panel_is_active
#include "game/area.h"             // gWarpTransition
#include "game/ingame_menu.h"      // gMenuMode
#include "game/level_update.h"     // gCurrCreditsEntry
#include "game/game_init.h"        // gCurrDemoInput
#include "pc/vision3d/sm64_vr_spike.h"  // sm64_vr_preset_cycle, anti-clip
#include "game/camera.h"           // gCamera
#include "engine/math_util.h"      // mtxf_inverse_non_affine
#include "engine/surface_collision.h"
#include "game/object_list_processor.h"  // gCheckingSurfaceCollisionsForCamera, gObjectLists
#include "game/interaction.h"       // INTERACT_GRABBABLE
#include "object_fields.h"         // oInteractType, oPosY, ... (the o* macros)
#include "object_constants.h"      // ACTIVE_FLAG_DEACTIVATED
#include "game/object_helpers.h"    // dist_between_objects
#include "pc/djui/djui_chat_box.h"  // the menu-button long press
#include "pc/network/network.h"     // gNetworkType: chat is networked-only
#include "game/first_person_cam.h" // the game's own first-person camera
#include "sm64.h"                 // ACT_TRIPLE_JUMP / ACT_BACKFLIP / ACT_SIDE_FLIP
#include <math.h>
#include "pc/utils/misc.h"       // clock_elapsed_f64
#include <string.h>

// The act/star selector (charter A5's hybrid case). It renders 3D star models
// behind 2D text, so no draw-order heuristic classifies it correctly — the donor
// added a game-side flag for exactly this and so do we. star_select.c stamps a
// few frames of grace each time its update runs, which also covers the moment
// either side of the load where it is still on screen.
//
// TIME-stamped, not frame-counted, and that distinction is the whole bug Austin
// hit (2026-08-08: "it does show the 2D screen, but the 3D screen is also
// flickering constantly - like two duplicates fighting over space"). The stamp
// is refilled once per SIM tick (30 Hz) but was being consumed once per RENDERED
// frame (90-120 Hz): four of each, so the slightest jitter emptied it, panel mode
// dropped for a frame, the stereo world drew, and the eye textures reallocated
// between the two aspects. A deadline in seconds cannot be raced by a rate ratio.
double gVrActSelectorUntil = 0.0;

bool sm64_vr_frame_is_nongameplay(void) {
    if (clock_elapsed_f64() < gVrActSelectorUntil) { return true; }
    // A door / level transition is a 2D fullscreen effect. In the stereo world
    // it would only cover the middle of your view; on the panel it fills the
    // screen the way it is meant to.
    if (gWarpTransition.isActive)  { return true; }
    if (gDjuiInMainMenu)           { return true; }  // title / main menu / connect / options
    // The VR panel is the ONE menu that stays in the world: its sliders describe
    // the world, and you cannot judge a world you just replaced with a menu.
    if (sm64_vr_spike_menu_over_world()) { return false; }
    if (djui_panel_is_active())    { return true; }  // every other in-game menu
    if (gCurrCreditsEntry != NULL) { return true; }  // credits / ending
    if (gCurrDemoInput != NULL)    { return true; }  // attract-mode demo
    if (gMenuMode != -1)           { return true; }  // pause star grid / course complete
    return false;                                    // active gameplay
}

// Keep coopdx's OWN first-person camera in step with the VR mode. The
// mismatch-only re-assert is the donor's network-reset survival (their
// pc_main.c:524-529): joining or leaving a lobby, and some Lua mods, clear the
// game-side flag without the VR mode changing, which used to leave the view
// broken until you cycled modes. The DISABLE direction stays change-only, so a
// player who turns on the game's own first-person in a non-VR mode keeps it.
void sm64_vr_sync_first_person(void) {
    static bool prev = false;
    bool want = sm64_vr_first_person_active();
    if (want != prev) {
        set_first_person_enabled(want);
        prev = want;
    } else if (want && !gFirstPersonCamera.enabled) {
        set_first_person_enabled(true);
    }
}

// FLIP CAM (charter R4). When Mario somersaults, the view somersaults with him.
// Off by default and it should stay that way for most people — it is a great
// trick that will make you ill over a session — but it is the kind of thing VR
// exists for, so it is a switch rather than an absence.
//
// The angle and the AXIS it belongs to are set together, never in two calls.
// That is the donor's hardest-won lesson here: the tilt eases over several
// frames while the axis is read from Mario's CURRENT action and switches in one,
// so split calls hand a decaying roll to the pitch axis mid-decay and the view
// twists onto an axis it was never leaning on.
// ONE turn, timed, and it stops. The first cut of this was wrong in two ways
// that compounded into Austin's device report ("it just flickers and does a
// first person somersault view like MANY times, and isn't smooth at all",
// 2026-08-08):
//
//  1. It advanced a FIXED step per call and this function is called once per
//     RENDERED frame, not once per sim tick. At 90 Hz against a step sized for
//     ~18 ticks, a single backflip spun the view several full turns — the "MANY
//     times". Nothing clamped it either, so a long action just kept going.
//  2. A fixed step per frame is by definition frame-rate-dependent, so the same
//     move span a different arc depending on load — the "isn't smooth".
//
// Both die the same way: integrate against the CLOCK, not against the call
// count, and stop dead at one full revolution. A full turn is the identity
// rotation, so completing it means snapping to zero rather than easing back
// down through the arc we just came up (which would read as an unwind).
#define VR_FLIP_SECONDS 0.60f   // one somersault, about the length of the move
#define VR_FLIP_TWO_PI  6.28318531f

void sm64_vr_update_flip_cam(void) {
    static float  angle = 0.0f;
    static bool   side = false;
    static bool   wasFlipping = false;
    static double lastTime = -1.0;

    double now = clock_elapsed_f64();
    float dt = (lastTime < 0.0) ? 0.0f : (float) (now - lastTime);
    lastTime = now;
    // A long stall (loading, a menu) must not teleport the view a third of a turn.
    if (dt > 0.1f) { dt = 0.1f; }

    struct MarioState *m = &gMarioStates[0];
    bool on = sm64_vr_first_person_active()
           && sm64_3d_setting_f("vrFlipCam", SM64_DEF_VRFLIPCAM) > 0.5f;
    if (!on || m == NULL) {
        if (angle != 0.0f || wasFlipping) {
            angle = 0.0f; wasFlipping = false; sm64_vr_set_flip(0.0f, false);
        }
        return;
    }

    u32 a = m->action;
    bool flipping = (a == ACT_TRIPLE_JUMP) || (a == ACT_BACKFLIP) || (a == ACT_SIDE_FLIP);

    if (flipping && !wasFlipping) {
        // A fresh flip starts from level on the axis this move belongs to. Angle
        // and axis are set in the SAME frame and handed over together below —
        // the donor's hardest-won lesson here, and still true.
        angle = 0.0f;
        side = (a == ACT_SIDE_FLIP);
    }
    wasFlipping = flipping;

    if (flipping && angle < VR_FLIP_TWO_PI) {
        float dir = (a == ACT_BACKFLIP) ? 1.0f : -1.0f;
        angle += (VR_FLIP_TWO_PI / VR_FLIP_SECONDS) * dt;
        if (angle >= VR_FLIP_TWO_PI) { angle = VR_FLIP_TWO_PI; }
        sm64_vr_set_flip(dir * angle, side);
        return;
    }
    if (!flipping && angle != 0.0f) {
        // Landed mid-turn: ease the REMAINDER of the revolution out rather than
        // rewinding, so the view finishes the way the body did.
        angle += (VR_FLIP_TWO_PI / VR_FLIP_SECONDS) * dt;
        if (angle >= VR_FLIP_TWO_PI) { angle = 0.0f; }
        float dir = side ? -1.0f : 1.0f;
        sm64_vr_set_flip(angle == 0.0f ? 0.0f : dir * angle, side);
        return;
    }
    sm64_vr_set_flip(0.0f, side);
}

// Switching stick-look mode has to level the pitch. In Turn and Snap the HEADSET
// owns pitch and the stick only yaws, so whatever pitch the game camera was
// carrying from Free mode becomes a fixed offset you cannot look out of — dial in
// Free while looking at your feet, switch to Turn, and you are stuck staring at
// the floor for good. Austin hit exactly that (2026-08-08).
void sm64_vr_sync_look_mode(void) {
    static int prev = -2;
    int mode = sm64_vr_stick_look_mode();
    if (mode != prev) {
        if (prev == 0 && (mode == 1 || mode == 2)) { gFirstPersonCamera.pitch = 0; }
        prev = mode;
    }
}

// D-pad UP cycles the view mode, so switching does not mean opening a menu
// inside the headset (donor pc_main.c:497-503). Edge-detected, and ignored while
// a menu panel is open so it cannot fight the menu's own d-pad navigation.
void sm64_vr_poll_hotkeys(void) {
    extern struct Controller *gPlayer1Controller;
    static u16 sPrevDpadUp = 0;
    u16 up = gPlayer1Controller ? (u16)(gPlayer1Controller->buttonDown & U_JPAD) : 0;
    if (up && !sPrevDpadUp && !djui_panel_is_active() && !gDjuiInMainMenu) {
        sm64_vr_preset_cycle();
    }
    sPrevDpadUp = up;
}

// GRAB GATE (charter A10, donor controller_vr.c:125-145). A grip squeeze becomes
// B only when there is actually something to grab, so an empty squeeze in open
// space does nothing instead of punching the air — which is what makes grips
// feel like grabbing rather than a second punch button.
bool sm64_vr_grabbable_in_reach(void) {
    struct MarioState *m = &gMarioStates[0];
    if (!m->marioObj) { return false; }
    if (m->heldObj) { return true; }   // already holding: the grip is the THROW
    static const enum ObjectList grabLists[] = {
        OBJ_LIST_GENACTOR, OBJ_LIST_DESTRUCTIVE, OBJ_LIST_PUSHABLE, OBJ_LIST_DEFAULT
    };
    for (size_t i = 0; i < sizeof(grabLists) / sizeof(grabLists[0]); i++) {
        struct ObjectNode *head = &gObjectLists[grabLists[i]];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (o->activeFlags == ACTIVE_FLAG_DEACTIVATED) { continue; }
            if (o->oInteractType != INTERACT_GRABBABLE) { continue; }
            if (o->oIntangibleTimer != 0) { continue; }
            if (fabsf(o->oPosY - m->pos[1]) > 200.0f + o->hitboxHeight) { continue; }
            if (dist_between_objects(m->marioObj, o) < 180.0f + o->hitboxRadius) { return true; }
        }
    }
    return false;
}

// Chat is the menu button's LONG press (donor's reasoning: it is the only
// gesture that cannot collide with gameplay). Networked-only, like theirs.
void sm64_vr_toggle_chat(void) {
    extern bool gDjuiChatBoxFocus;
    if (gNetworkType == NT_NONE) { return; }
    djui_chat_box_toggle();
    (void)gDjuiChatBoxFocus;
}

// ---------------------------------------------------------------------------
// ANTI-CLIP, the collision half (charter R2, donor pc_main.c:313-405).
//
// The geometric standoff in the loop keeps the world off your FACE. This keeps
// your viewpoint out of the world's GEOMETRY: the VR side hands us the cyclopean
// eye in game-camera space, we convert it to world units through the renderer's
// camera matrix, run the level's own floor/ceiling/wall collision on it, and
// hand back the offset (in metres) that nudges the whole shrunk world off
// whatever the eye was inside. One frame of latency by construction — the offset
// we compute now is applied to the next frame's anchor — which is why it is
// eased rather than applied raw.
//
// Runs on the ENGINE thread (the frame poll), because level collision is engine
// state and the compositor thread must never touch it.
void sm64_vr_anticlip_resolve(void) {
    static float applied[3] = { 0.0f, 0.0f, 0.0f };
    float target[3] = { 0.0f, 0.0f, 0.0f };
    float camPos[3];
    bool active = sm64_vr_anticlip_get_head_campos(camPos) && (gCamera != NULL);

    if (active) {
        Mat4 inv;
        if (mtxf_inverse_non_affine(inv, gCamera->mtx)) {
            // camera space (row vector) -> world
            float wx = camPos[0]*inv[0][0] + camPos[1]*inv[1][0] + camPos[2]*inv[2][0] + inv[3][0];
            float wy = camPos[0]*inv[0][1] + camPos[1]*inv[1][1] + camPos[2]*inv[2][1] + inv[3][1];
            float wz = camPos[0]*inv[0][2] + camPos[1]*inv[1][2] + camPos[2]*inv[2][2] + inv[3][2];
            // find_floor casts to s16 internally; keep it in range.
            if (wx < -30000.0f) { wx = -30000.0f; } else if (wx > 30000.0f) { wx = 30000.0f; }
            if (wz < -30000.0f) { wz = -30000.0f; } else if (wz > 30000.0f) { wz = 30000.0f; }

            float scale = sm64_vr_anticlip_world_scale();
            float marginWU = 0.10f * scale;   // a 10 cm physical standoff, in world units

            float cwx = wx, cwy = wy, cwz = wz;
            gCheckingSurfaceCollisionsForCamera = TRUE;

            struct Surface *floor = NULL, *ceil = NULL;
            float fY = find_floor(cwx, cwy, cwz, &floor);
            float cY = find_ceil(cwx, cwy, cwz, &ceil);
            bool haveFloor = (floor != NULL) && (fY > -10000.0f);
            bool haveCeil  = (ceil  != NULL) && (cY <  19000.0f);
            if (haveFloor && cwy < fY + marginWU) { cwy = fY + marginWU; }
            if (haveCeil  && cwy > cY - marginWU) { cwy = cY - marginWU; }
            if (haveFloor && haveCeil && fY + marginWU > cY - marginWU) { cwy = 0.5f * (fY + cY); }

            struct WallCollisionData wcd;
            memset(&wcd, 0, sizeof(wcd));
            wcd.x = cwx; wcd.y = cwy; wcd.z = cwz; wcd.offsetY = 0.0f; wcd.radius = marginWU;
            find_wall_collisions(&wcd);
            cwx = wcd.x; cwz = wcd.z;

            // A wall push can slide us over a step — re-clamp the floor once.
            fY = find_floor(cwx, cwy, cwz, &floor);
            if (floor != NULL && fY > -10000.0f && cwy < fY + marginWU) { cwy = fY + marginWU; }

            gCheckingSurfaceCollisionsForCamera = FALSE;

            float dwx = cwx - wx, dwy = cwy - wy, dwz = cwz - wz;
            // world delta -> camera space (rotation rows only) -> metres, negated:
            // move the WORLD opposite to the eye pushout, so the fixed head ends
            // up outside the geometry.
            float dcx = dwx*gCamera->mtx[0][0] + dwy*gCamera->mtx[1][0] + dwz*gCamera->mtx[2][0];
            float dcy = dwx*gCamera->mtx[0][1] + dwy*gCamera->mtx[1][1] + dwz*gCamera->mtx[2][1];
            float dcz = dwx*gCamera->mtx[0][2] + dwy*gCamera->mtx[1][2] + dwz*gCamera->mtx[2][2];
            float invScale = 1.0f / scale;
            target[0] = -dcx * invScale;
            target[1] = -dcy * invScale;
            target[2] = -dcz * invScale;
        } else {
            active = false;
        }
    }

    // Escape geometry FAST so a quick camera move cannot dip the view through a
    // floor before the correction catches up; relax back slowly so the world
    // never lurches. "Escaping" = the correction is growing.
    for (int i = 0; i < 3; i++) {
        float d = target[i] - applied[i];
        float at = (target[i]  < 0.0f) ? -target[i]  : target[i];
        float aa = (applied[i] < 0.0f) ? -applied[i] : applied[i];
        float maxStep = !active ? 0.04f : ((at > aa) ? 0.10f : 0.02f);
        if (d >  maxStep) { d =  maxStep; }
        if (d < -maxStep) { d = -maxStep; }
        applied[i] += d;
        if (applied[i] >  0.80f) { applied[i] =  0.80f; }
        if (applied[i] < -0.80f) { applied[i] = -0.80f; }
    }
    sm64_vr_anticlip_set_offset(applied);
}

#endif // SM64_VISION_3D
