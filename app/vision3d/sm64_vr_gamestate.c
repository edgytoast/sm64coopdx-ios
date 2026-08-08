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
#include "game/object_list_processor.h"  // gCheckingSurfaceCollisionsForCamera
#include <string.h>

// The act/star selector (charter A5's hybrid case). It renders 3D star models
// behind 2D text, so no draw-order heuristic classifies it correctly — the donor
// added a game-side flag for exactly this and so do we. star_select.c stamps a
// few frames of grace each time its update runs, which also covers the moment
// either side of the load where it is still on screen.
int gVrActSelectorFrames = 0;

bool sm64_vr_frame_is_nongameplay(void) {
    if (gVrActSelectorFrames > 0) { gVrActSelectorFrames--; return true; }
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
