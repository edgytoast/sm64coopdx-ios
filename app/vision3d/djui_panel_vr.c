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
    if (sUiMsaa < (unsigned int) VR_MSAA_COUNT) {
        sm64_3d_setting_set_f("vrMsaa", (float) sMsaaSamples[sUiMsaa]);
    }
    sm64_3d_apply_settings();
}

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
