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
#include "pc/vision3d/sm64_vr_spike.h"  // sm64_vr_preset_cycle

bool sm64_vr_frame_is_nongameplay(void) {
    // A door / level transition is a 2D fullscreen effect. In the stereo world
    // it would only cover the middle of your view; on the panel it fills the
    // screen the way it is meant to.
    if (gWarpTransition.isActive)  { return true; }
    if (gDjuiInMainMenu)           { return true; }  // title / main menu / connect / options
    if (djui_panel_is_active())    { return true; }  // in-game menus, including the VR panel
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

#endif // SM64_VISION_3D
