// sm64_vr_presets.c — VR view modes (charter R2, donor vr.c:1493-1556).
//
// A "mode" is just a remembered set of placement numbers, and the donor's design
// has one property worth copying exactly: the tweaks you make while a mode is
// active are remembered FOR THAT MODE. Switching Diorama -> Third-person ->
// Diorama brings your Diorama back, rather than handing you the stock table
// again. That is what makes the sliders worth touching.
//
// HOW THE MEMORY WORKS, and why it is not per-mode keys everywhere: the two
// menus (the in-game panel and the visionOS sheet) both edit ONE live set of
// keys — "vrScale", "vrDist", ... — which is what lets them stay simple and stay
// in agreement. Switching modes SNAPSHOTS the live set into the outgoing mode's
// slot and loads the incoming mode's slot over it. So the menus never need to
// know modes exist, and a mode is a slot, not a second source of truth.

#include "pc/vision3d/sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#include <stdio.h>
#include <string.h>

typedef struct {
    const char *name;
    float scale;    // game units per metre (bigger = smaller world)
    float dist;     // metres in front of you the game's camera sits
    float height;   // metres relative to eye level
} SM64VrPreset;

// Stock table. Diorama is ours, tuned on device; Third-person follows the
// donor's shape — a bigger world whose camera sits essentially AT you, so the
// level is around you rather than on a table in front of you.
// Austin, 2026-08-08: "the difference between diorama and 3rd person feels more
// like how zoomed in you are. is that right?" — it was, and that is the honest
// answer for any mode short of first-person: what changes is the world's SIZE
// and where you stand in it. So the two are now pulled far enough apart to be
// two places rather than two zoom levels:
//   Diorama      a ~3.6 m world, in front of you and well below eye level —
//                something on a table that you look DOWN at.
//   Third-person a ~9 m world with the game's camera essentially AT you, so the
//                level is around you and Mario is a foot tall.
static const SM64VrPreset sPresets[] = {
    { "Diorama",      2200.0f,  0.55f, -0.60f },
    { "Third-person",  900.0f, -0.15f, -0.10f },
};
#define SM64_VR_PRESET_COUNT ((int)(sizeof(sPresets) / sizeof(sPresets[0])))

int         sm64_vr_preset_count(void) { return SM64_VR_PRESET_COUNT; }
const char *sm64_vr_preset_name(int i) {
    return (i >= 0 && i < SM64_VR_PRESET_COUNT) ? sPresets[i].name : "";
}

int sm64_vr_preset_get(void) {
    int idx = (int) sm64_3d_setting_f("vrPreset", 0.0f);
    if (idx < 0 || idx >= SM64_VR_PRESET_COUNT) { idx = 0; }
    return idx;
}

// Per-slot keys: "vrP0Scale", "vrP1Dist", ...
static void slot_key(char *out, size_t n, int idx, const char *field) {
    snprintf(out, n, "vrP%d%s", idx, field);
}

static void slot_save(int idx) {
    char k[32];
    slot_key(k, sizeof(k), idx, "Scale");  sm64_3d_setting_set_f(k, sm64_3d_setting_f("vrScale", sPresets[idx].scale));
    slot_key(k, sizeof(k), idx, "Dist");   sm64_3d_setting_set_f(k, sm64_3d_setting_f("vrDist", sPresets[idx].dist));
    slot_key(k, sizeof(k), idx, "Height"); sm64_3d_setting_set_f(k, sm64_3d_setting_f("vrHeight", sPresets[idx].height));
    slot_key(k, sizeof(k), idx, "Seed");   sm64_3d_setting_set_f(k, 1.0f);
}

static void slot_load(int idx) {
    char k[32];
    // An unseeded slot falls back to the stock table — that is what makes the
    // FIRST switch into a mode show the mode, rather than zeros.
    slot_key(k, sizeof(k), idx, "Seed");
    bool seeded = sm64_3d_setting_f(k, 0.0f) > 0.5f;
    if (!seeded) {
        sm64_3d_setting_set_f("vrScale", sPresets[idx].scale);
        sm64_3d_setting_set_f("vrDist", sPresets[idx].dist);
        sm64_3d_setting_set_f("vrHeight", sPresets[idx].height);
        return;
    }
    slot_key(k, sizeof(k), idx, "Scale");  sm64_3d_setting_set_f("vrScale", sm64_3d_setting_f(k, sPresets[idx].scale));
    slot_key(k, sizeof(k), idx, "Dist");   sm64_3d_setting_set_f("vrDist", sm64_3d_setting_f(k, sPresets[idx].dist));
    slot_key(k, sizeof(k), idx, "Height"); sm64_3d_setting_set_f("vrHeight", sm64_3d_setting_f(k, sPresets[idx].height));
}

void sm64_vr_preset_apply(int idx) {
    if (idx < 0 || idx >= SM64_VR_PRESET_COUNT) { return; }
    int cur = sm64_vr_preset_get();
    if (cur != idx) { slot_save(cur); }   // keep what you dialled in
    slot_load(idx);
    sm64_3d_setting_set_f("vrPreset", (float) idx);
    sm64_3d_apply_settings();
    printf("[vr] mode %d/%d: %s (scale=%.0f dist=%.2f height=%.2f)\n",
           idx + 1, SM64_VR_PRESET_COUNT, sPresets[idx].name,
           sm64_3d_setting_f("vrScale", 0.0f), sm64_3d_setting_f("vrDist", 0.0f),
           sm64_3d_setting_f("vrHeight", 0.0f));
}

// Is the ACTIVE mode first-person? No such mode exists yet (charter R4), so this
// is false today — but the hand-shaped gestures are gated on it rather than on
// nothing, so adding the mode turns them on instead of needing them found again.
bool sm64_vr_first_person_active(void) {
    return false;   // R4: becomes `sm64_vr_preset_get() == PRESET_FIRST_PERSON`
}

void sm64_vr_preset_cycle(void) {
    sm64_vr_preset_apply((sm64_vr_preset_get() + 1) % SM64_VR_PRESET_COUNT);
}

// Reset the ACTIVE mode to its stock numbers (the panel's Reset button).
void sm64_vr_preset_reset_current(void) {
    int idx = sm64_vr_preset_get();
    char k[32];
    slot_key(k, sizeof(k), idx, "Seed");
    sm64_3d_setting_set_f(k, 0.0f);   // un-seed, so the stock table wins
    slot_load(idx);
    sm64_3d_apply_settings();
}

#endif // SM64_VISION_3D
