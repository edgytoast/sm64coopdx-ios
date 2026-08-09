// djui_panel_vr.c — the in-game VR options panel (Options -> VR).
//
// See djui_panel_vr.h for why this exists and what belongs here rather than in
// the visionOS settings sheet.
//
// DJUI sliders carry `unsigned int` and no unit, so every row below keeps its
// value in whatever integer unit READS best in the menu (centimetres, percent,
// game-units-per-metre) and converts on the way in and out. The store is the
// shell's, shared with the sheet — this panel never keeps state of its own
// beyond the widget mirrors, so opening it always shows the truth.

#include "pc/vision3d/djui_panel_vr.h"

#ifdef SM64_VISION_3D

#include "pc/djui/djui.h"
#include "pc/djui/djui_panel.h"
#include "pc/djui/djui_panel_menu.h"
#include "pc/vision3d/sm64_vr_spike.h"
#include <stdio.h>
#include "pc/vision3d/sm64_vr_hands.h"
#include "pc/vision3d/controller_vision.h"  // the pad inventory row  // the hands status line

// Widget mirrors, in menu units.
static unsigned int sUiScale;    // game units per metre (a bigger world number = a smaller world)
static unsigned int sUiDist;     // centimetres in front of you
static unsigned int sUiHeight;   // centimetres, offset by VR_HEIGHT_BIAS so the slider can go negative
static unsigned int sUiStereo;   // percent of a true IPD
static unsigned int sUiRender;   // percent of the per-eye view resolution
static unsigned int sUiDim;      // percent
static unsigned int sUiMsaa;     // index into sMsaaChoices
static unsigned int sUiMode;     // view mode (sm64_vr_presets.c)
static bool sUiWorldLock;
static unsigned int sUiLookMode; // 0 Free, 1 Turn, 2 Snap
static unsigned int sUiLookSens; // percent
static bool sUiFlipCam;          // somersault the view with Mario
static bool sUiHands;            // draw Mario's hands on your controllers
static bool sUiInputNative;      // EXPERIMENTAL: fixed VR layout instead of SDL
static unsigned int sUiHandSize; // percent of Mario's own hand geometry
static unsigned int sUiHandStyle; // 0 prim, 1 env, 2 shade, 3 lit
static unsigned int sUiHandYaw;   // +180 bias: DJUI sliders are unsigned
static unsigned int sUiHandPitch;
static unsigned int sUiHandRoll;
static unsigned int sUiRHandYaw, sUiRHandPitch, sUiRHandRoll;
static unsigned int sUiHandOffZ, sUiHandOffY, sUiHandOffX;  // +30 bias == -0.30..+0.30 m
#define VR_OFF_BIAS 30
static bool sUiGrabHands;
static bool sUiPunchHands;
#define VR_ANGLE_BIAS 180        // slider 0..360 == -180..+180 degrees

// DJUI sliders are unsigned, and the world can sit BELOW eye level (it usually
// should — you look down at a diorama), so the height row carries a bias.
#define VR_HEIGHT_BIAS 150   // slider 0..200 == -1.50 m .. +0.50 m
// Distance can be NEGATIVE: third-person puts the game's camera essentially
// at you, so the level surrounds you instead of sitting in front of you.
#define VR_DIST_BIAS 50      // slider 0..350 == -0.50 m .. +3.00 m

static const int sMsaaSamples[] = { 1, 2, 4, 8 };
#define VR_MSAA_COUNT ((int)(sizeof(sMsaaSamples) / sizeof(sMsaaSamples[0])))

static unsigned int vr_msaa_index_of(int samples) {
    for (int i = 0; i < VR_MSAA_COUNT; i++) {
        if (sMsaaSamples[i] == samples) { return (unsigned int) i; }
    }
    return 0;
}

// Read the store into the widget mirrors. Called at panel creation so the rows
// always show what is actually live, including anything changed from the sheet.
static void vr_panel_pull(void) {
    sUiScale     = (unsigned int) sm64_3d_setting_f("vrScale", SM64_DEF_VRSCALE);
    sUiDist      = (unsigned int) (sm64_3d_setting_f("vrDist", SM64_DEF_VRDIST) * 100.0f
                                   + VR_DIST_BIAS);
    sUiHeight    = (unsigned int) (sm64_3d_setting_f("vrHeight", SM64_DEF_VRHEIGHT) * 100.0f
                                   + VR_HEIGHT_BIAS);
    sUiStereo    = (unsigned int) (sm64_3d_setting_f("vrStereo", SM64_DEF_VRSTEREO) * 100.0f);
    sUiRender    = (unsigned int) (sm64_3d_setting_f("vrRender", SM64_DEF_VRRENDER) * 100.0f);
    sUiDim       = (unsigned int) (sm64_3d_setting_f("vrDim", SM64_DEF_VRDIM) * 100.0f);
    sUiMsaa      = vr_msaa_index_of((int) sm64_3d_setting_f("vrMsaa", SM64_DEF_VRMSAA));
    sUiWorldLock = sm64_3d_setting_f("vrLock", SM64_DEF_VRWORLDLOCK) > 0.5f;
    sUiMode      = (unsigned int) sm64_vr_preset_get();
    sUiLookMode  = (unsigned int) sm64_3d_setting_f("vrLookMode", SM64_DEF_VRLOOKMODE);
    sUiLookSens  = (unsigned int) (sm64_3d_setting_f("vrLookSens", SM64_DEF_VRLOOKSENS) * 100.0f);
    sUiFlipCam   = sm64_3d_setting_f("vrFlipCam", SM64_DEF_VRFLIPCAM) > 0.5f;
    sUiHands     = sm64_3d_setting_f("vrHands", SM64_DEF_VRHANDS) > 0.5f;
    sUiInputNative = sm64_3d_setting_f("vrInputNative", SM64_DEF_VRINPUTNATIVE) > 0.5f;
    sUiHandSize  = (unsigned int) (sm64_3d_setting_f("vrHandSize", SM64_DEF_VRHANDSIZE) * 100.0f);
    sUiHandStyle = (unsigned int) sm64_3d_setting_f("vrHandStyle", SM64_DEF_VRHANDSTYLE);
    sUiHandYaw   = (unsigned int) (sm64_3d_setting_f("vrHandYaw", SM64_DEF_VRHANDYAW) + VR_ANGLE_BIAS);
    sUiHandPitch = (unsigned int) (sm64_3d_setting_f("vrHandPitch", SM64_DEF_VRHANDPITCH) + VR_ANGLE_BIAS);
    sUiHandRoll  = (unsigned int) (sm64_3d_setting_f("vrHandRoll", SM64_DEF_VRHANDROLL) + VR_ANGLE_BIAS);
    sUiRHandYaw   = (unsigned int) (sm64_3d_setting_f("vrRHandYaw", SM64_DEF_VRHANDYAW) + VR_ANGLE_BIAS);
    sUiRHandPitch = (unsigned int) (sm64_3d_setting_f("vrRHandPitch", SM64_DEF_VRHANDPITCH) + VR_ANGLE_BIAS);
    sUiRHandRoll  = (unsigned int) (sm64_3d_setting_f("vrRHandRoll", SM64_DEF_VRHANDROLL) + VR_ANGLE_BIAS);
    sUiHandOffZ = (unsigned int) (sm64_3d_setting_f("vrHandOffZ", 0.0f) * 100.0f + VR_OFF_BIAS);
    sUiHandOffY = (unsigned int) (sm64_3d_setting_f("vrHandOffY", 0.0f) * 100.0f + VR_OFF_BIAS);
    sUiHandOffX = (unsigned int) (sm64_3d_setting_f("vrHandOffX", 0.0f) * 100.0f + VR_OFF_BIAS);
    sUiGrabHands  = sm64_3d_setting_f("vrGestureGrab", SM64_DEF_VRGESTUREGRAB) > 0.5f;
    sUiPunchHands = sm64_3d_setting_f("vrGesturePunch", SM64_DEF_VRGESTUREPUNCH) > 0.5f;
}

// Switching modes restores that mode's own numbers, so the sliders below have to
// follow — otherwise they would show the mode you just left.
static void vr_panel_mode_changed(UNUSED struct DjuiBase *caller) {
    sm64_vr_preset_apply((int) sUiMode);
    vr_panel_pull();
}

// Write the mirrors back and apply. Applying LIVE is the whole point: these are
// numbers you can only judge by looking at the world while you drag them, which
// is exactly how the donor's were tuned.
static void vr_panel_push(UNUSED struct DjuiBase *caller) {
    sm64_3d_setting_set_f("vrScale", (float) sUiScale);
    sm64_3d_setting_set_f("vrDist", ((float) sUiDist - VR_DIST_BIAS) / 100.0f);
    sm64_3d_setting_set_f("vrHeight", ((float) sUiHeight - VR_HEIGHT_BIAS) / 100.0f);
    sm64_3d_setting_set_f("vrStereo", (float) sUiStereo / 100.0f);
    sm64_3d_setting_set_f("vrRender", (float) sUiRender / 100.0f);
    sm64_3d_setting_set_f("vrDim", (float) sUiDim / 100.0f);
    sm64_3d_setting_set_f("vrLock", sUiWorldLock ? 1.0f : 0.0f);
    sm64_3d_setting_set_f("vrLookMode", (float) sUiLookMode);
    sm64_3d_setting_set_f("vrLookSens", (float) sUiLookSens / 100.0f);
    sm64_3d_setting_set_f("vrFlipCam", sUiFlipCam ? 1.0f : 0.0f);
    sm64_3d_setting_set_f("vrHands", sUiHands ? 1.0f : 0.0f);
    sm64_3d_setting_set_f("vrInputNative", sUiInputNative ? 1.0f : 0.0f);
    sm64_3d_setting_set_f("vrHandSize", (float) sUiHandSize / 100.0f);
    sm64_3d_setting_set_f("vrHandStyle", (float) sUiHandStyle);
    sm64_3d_setting_set_f("vrHandYaw", (float) sUiHandYaw - VR_ANGLE_BIAS);
    sm64_3d_setting_set_f("vrHandPitch", (float) sUiHandPitch - VR_ANGLE_BIAS);
    sm64_3d_setting_set_f("vrHandRoll", (float) sUiHandRoll - VR_ANGLE_BIAS);
    sm64_3d_setting_set_f("vrRHandYaw", (float) sUiRHandYaw - VR_ANGLE_BIAS);
    sm64_3d_setting_set_f("vrRHandPitch", (float) sUiRHandPitch - VR_ANGLE_BIAS);
    sm64_3d_setting_set_f("vrRHandRoll", (float) sUiRHandRoll - VR_ANGLE_BIAS);
    sm64_3d_setting_set_f("vrHandOffZ", ((float) sUiHandOffZ - VR_OFF_BIAS) / 100.0f);
    sm64_3d_setting_set_f("vrHandOffY", ((float) sUiHandOffY - VR_OFF_BIAS) / 100.0f);
    sm64_3d_setting_set_f("vrHandOffX", ((float) sUiHandOffX - VR_OFF_BIAS) / 100.0f);
    sm64_3d_setting_set_f("vrGestureGrab", sUiGrabHands ? 1.0f : 0.0f);
    sm64_3d_setting_set_f("vrGesturePunch", sUiPunchHands ? 1.0f : 0.0f);
    if (sUiMsaa < (unsigned int) VR_MSAA_COUNT) {
        sm64_3d_setting_set_f("vrMsaa", (float) sMsaaSamples[sUiMsaa]);
    }
    sm64_3d_apply_settings();
}

static char sHandsStatus[64];
static char sTexStatus[64];
static char sPadStatus[128];

// The hands status row is a readout, not a control.
static void vr_panel_noop(UNUSED struct DjuiBase *caller) { }

static void vr_panel_recenter(UNUSED struct DjuiBase *caller) {
    sm64_vr_spike_recenter();
}

static void vr_panel_reset(UNUSED struct DjuiBase *caller) {
    // Placement goes back to the ACTIVE mode's stock numbers, not to Diorama's:
    // "reset" in a mode should mean "this mode, as it shipped".
    sm64_vr_preset_reset_current();
    sm64_3d_setting_set_f("vrStereo", SM64_DEF_VRSTEREO);
    sm64_3d_setting_set_f("vrRender", SM64_DEF_VRRENDER);
    sm64_3d_setting_set_f("vrDim", SM64_DEF_VRDIM);
    sm64_3d_setting_set_f("vrLock", SM64_DEF_VRWORLDLOCK);
    sm64_3d_setting_set_f("vrMsaa", SM64_DEF_VRMSAA);
    sm64_3d_setting_set_f("vrLookMode", SM64_DEF_VRLOOKMODE);
    sm64_3d_setting_set_f("vrLookSens", SM64_DEF_VRLOOKSENS);
    sm64_3d_setting_set_f("vrFlipCam", SM64_DEF_VRFLIPCAM);
    sm64_3d_setting_set_f("vrHands", SM64_DEF_VRHANDS);
    sm64_3d_setting_set_f("vrInputNative", SM64_DEF_VRINPUTNATIVE);
    sm64_3d_setting_set_f("vrHandSize", SM64_DEF_VRHANDSIZE);
    sm64_3d_setting_set_f("vrHandStyle", SM64_DEF_VRHANDSTYLE);
    sm64_3d_setting_set_f("vrHandYaw", SM64_DEF_VRHANDYAW);
    sm64_3d_setting_set_f("vrHandPitch", SM64_DEF_VRHANDPITCH);
    sm64_3d_setting_set_f("vrHandRoll", SM64_DEF_VRHANDROLL);
    sm64_3d_setting_set_f("vrGestureGrab", SM64_DEF_VRGESTUREGRAB);
    sm64_3d_setting_set_f("vrGesturePunch", SM64_DEF_VRGESTUREPUNCH);
    vr_panel_pull();
    sm64_3d_apply_settings();
    // No panel rebuild: DJUI sliders read *value when they RENDER
    // (djui_slider.c:135), so restoring the mirrors moves the bars on their own.
    // Tearing the panel down and re-adding it from inside a button callback
    // would mean using `caller` after its own panel was freed.
}

// While THIS panel is open the world stays in stereo behind it, so every slider
// can be judged against the thing it changes. DJUI tells us when the panel goes
// away through on_panel_destroy, which is the only reliable end-of-life signal —
// Back, Escape and a panel-stack unwind all route through it.
static void vr_panel_destroyed(UNUSED struct DjuiBase *caller) {
    sm64_vr_spike_set_menu_over_world(0);
}

void djui_panel_vr_create(struct DjuiBase *caller) {
    vr_panel_pull();

    struct DjuiThreePanel *panel = djui_panel_menu_create("VR", false);
    struct DjuiBase *body = djui_three_panel_get_body(panel);
    {
        // The mode comes first because it MOVES the rows under it: each mode
        // remembers its own placement, and picking one loads that set.
        {
            int n = sm64_vr_preset_count();
            if (n > 4) { n = 4; }
            char *choices[4];
            for (int i = 0; i < n; i++) { choices[i] = (char *) sm64_vr_preset_name(i); }
            djui_selectionbox_create(body, "VR Mode", choices, (u8) n, &sUiMode,
                                     vr_panel_mode_changed);
        }

        // Placement: this is the group that decides whether the world feels like
        // a toy on a table or a place you are standing in.
        djui_slider_create(body, "World Size", &sUiScale, 300, 6000, vr_panel_push);
        djui_slider_create(body, "World Distance", &sUiDist, 0, 350, vr_panel_push);
        djui_slider_create(body, "World Height", &sUiHeight, 0, 200, vr_panel_push);
        djui_checkbox_create(body, "World Lock", &sUiWorldLock, vr_panel_push);
        // First-person look. Turn and Snap both leave pitch to the headset,
        // which already owns it; Free is the flat-screen behaviour.
        {
            char *look[3] = { "Free", "Turn", "Snap" };
            djui_selectionbox_create(body, "Stick Look", look, 3, &sUiLookMode, vr_panel_push);
        }
        djui_slider_create(body, "Look Sensitivity", &sUiLookSens, 20, 300, vr_panel_push);
        djui_checkbox_create(body, "Flip Cam (intense)", &sUiFlipCam, vr_panel_push);
        // Charter R4. Drawn only in first-person, and only while a controller is
        // actually pose-tracked — see sm64_vr_hands.m for why that is an open
        // question on this hardware rather than a given.
        djui_checkbox_create(body, "Show Mario Hands", &sUiHands, vr_panel_push);
        djui_slider_create(body, "Hand Size", &sUiHandSize, 2, 200, vr_panel_push);
        djui_slider_create(body, "Hand Style", &sUiHandStyle, 0, 3, vr_panel_push);
        djui_slider_create(body, "L Hand Yaw", &sUiHandYaw, 0, 360, vr_panel_push);
        djui_slider_create(body, "L Hand Pitch", &sUiHandPitch, 0, 360, vr_panel_push);
        djui_slider_create(body, "L Hand Roll", &sUiHandRoll, 0, 360, vr_panel_push);
        djui_slider_create(body, "R Hand Yaw", &sUiRHandYaw, 0, 360, vr_panel_push);
        djui_slider_create(body, "R Hand Pitch", &sUiRHandPitch, 0, 360, vr_panel_push);
        djui_slider_create(body, "R Hand Roll", &sUiRHandRoll, 0, 360, vr_panel_push);
        djui_slider_create(body, "Hand Out (fwd)", &sUiHandOffZ, 0, 60, vr_panel_push);
        djui_slider_create(body, "Hand Up", &sUiHandOffY, 0, 60, vr_panel_push);
        djui_slider_create(body, "Hand Side", &sUiHandOffX, 0, 60, vr_panel_push);
        djui_checkbox_create(body, "Grab With Hands", &sUiGrabHands, vr_panel_push);
        djui_checkbox_create(body, "Punch With Hands", &sUiPunchHands, vr_panel_push);
        // EXPERIMENTAL, default OFF. On: the Sense pair leaves SDL and is driven
        // by the fixed VR layout. Reachable from the game's own menu on purpose —
        // if it misbehaves you can turn it off from inside the headset, which is
        // exactly what 1.1.2.22 left Austin unable to do.
        djui_checkbox_create(body, "VR Controller Input", &sUiInputNative, vr_panel_push);
        // Why there are no hands, readable from inside the headset. A button
        // purely because DJUI has no static-text row here; it does nothing.
        // Snapshot taken at panel creation, which is when you come looking.
        sm64_vr_hands_status(sHandsStatus, (int) sizeof(sHandsStatus));
        djui_button_create(body, sHandsStatus, DJUI_BUTTON_STYLE_NORMAL, vr_panel_noop);
        // Texture-cache wraps. Non-zero means the cache is recycling, which is
        // the condition the white-sky bug needed; zero means the cause is gone
        // rather than merely masked by the Metal texture-lifetime fix.
        {
            extern int sm64_gfx_texture_wraps(void);
            snprintf(sTexStatus, sizeof(sTexStatus), "Texture cache wraps: %d",
                     sm64_gfx_texture_wraps());
            djui_button_create(body, sTexStatus, DJUI_BUTTON_STYLE_NORMAL, vr_panel_noop);
        }
        // What GameController actually sees. Category "Spatial Controller"
        // confirms the SpatialGamepad declaration took, and whether the old
        // aggregate MFi device persists beside the pair.
        sm64_vr_pad_status(sPadStatus, (int) sizeof(sPadStatus));
        djui_button_create(body, sPadStatus, DJUI_BUTTON_STYLE_NORMAL, vr_panel_noop);

        // Comfort and image.
        djui_slider_create(body, "Stereo Depth", &sUiStereo, 0, 100, vr_panel_push);
        djui_slider_create(body, "Surroundings Dimming", &sUiDim, 0, 100, vr_panel_push);
        djui_slider_create(body, "Render Scale", &sUiRender, 40, 120, vr_panel_push);
        {
            char *choices[VR_MSAA_COUNT] = { "Off", "2x", "4x", "8x" };
            djui_selectionbox_create(body, "Antialiasing", choices, VR_MSAA_COUNT,
                                     &sUiMsaa, vr_panel_push);
        }

        djui_button_create(body, "Recenter World", DJUI_BUTTON_STYLE_NORMAL, vr_panel_recenter);
        djui_button_create(body, "Reset to Default", DJUI_BUTTON_STYLE_NORMAL, vr_panel_reset);
        djui_button_create(body, DLANG(MENU, BACK), DJUI_BUTTON_STYLE_BACK, djui_panel_menu_back);
    }

    struct DjuiPanel *added = djui_panel_add(caller, panel, NULL);
    if (added != NULL) { added->on_panel_destroy = vr_panel_destroyed; }
    sm64_vr_spike_set_menu_over_world(1);
}

#endif // SM64_VISION_3D
