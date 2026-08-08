// sm64_vr_hands.m — accessory poses, so Mario's hands can be YOUR hands.
//
// THE OPEN QUESTION THIS FILE EXISTS TO ANSWER. On this system the PSVR2 Sense
// pair enumerates as ONE `MFi` gamepad, not as two GCProductCategorySpatial-
// Controller devices (device log, 2026-08-08). controller_vision.m saw that and
// took the correct decision for INPUT — leave the pair to SDL's normal binds —
// but it also made the accessory-load call unreachable, because that call sat
// behind the same spatial-category gate. So nobody has ever actually asked ARKit
// whether it can track the thing.
//
// It is a fair question either way. ar_accessory_load_from_device takes a
// GCDevice, not a spatial controller, and accessory tracking is documented in
// terms of "accessories" rather than in terms of that product category; a
// controller that reports as MFi for INPUT may still be trackable. Or it may
// not, in which case there are no per-hand poses to be had and hands are dead on
// this hardware. So the load is attempted on EVERY controller and the result is
// logged loudly. One headset round answers it.
//
// WHAT WE DO WITH A POSE. ARKit gives origin-relative transforms in metres. The
// engine wants model->CAMERA, because that is the space our EyeVP consumes
// (gfx_stereo_projection composes MP = modelview * EyeVP). The chain is exactly
// the head anti-clip's chain applied to a different point, so it is reused
// rather than re-derived: A maps game-camera space to the room, so inverse(A)
// maps the room back to game-camera space, and the hand's model matrix is
// inverse(A) * accessoryPose.
//
// A SEPARATE ARKit SESSION, deliberately. The VR loop's session is created once,
// at loop start, with the world-tracking provider — but accessories load
// ASYNCHRONOUSLY and controllers connect and disconnect whenever they like, so
// the set of accessories is simply not known at that moment. Running accessory
// tracking on its own session sidesteps the ordering problem entirely and keeps
// its failure modes off the world tracking that the whole VR mode depends on:
// if this session never starts, the world is exactly as it was and only the
// hands are missing.

#import "sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>

#include "pc/vision3d/sm64_vr_hands.h"
#include "pc/vision3d/sm64_vr_spike.h"   // first-person gate, camera-from-world

// ---------------------------------------------------------------------------
// State. Written on whichever thread ARKit and GameController call us on, read
// by the compositor thread's poll and the engine thread's matrix query. The
// poses are plain float storage guarded by a validity flag published last, the
// same discipline the rest of the VR state uses.
// ---------------------------------------------------------------------------
#define SM64_VR_MAX_ACCESSORIES 4

API_AVAILABLE(visionos(26.0))
static ar_accessory_t sAccessory[SM64_VR_MAX_ACCESSORIES];
static GCController  *sAccessoryDevice[SM64_VR_MAX_ACCESSORIES];
static int            sAccessoryCount = 0;

API_AVAILABLE(visionos(26.0))
static ar_accessory_tracking_provider_t sProvider = NULL;
API_AVAILABLE(visionos(26.0))
static ar_session_t sSession = NULL;
static bool sProviderDirty = false;     // the accessory set changed; rebuild

static simd_float4x4 sHandWorld[2];     // origin_from_anchor, metres
static volatile int  sHandValid[2] = { 0, 0 };
static int           sHandsEnabled = 1;
static float         sHandScale = 1.0f;

// Diagnostics: this is a feature whose first question is "does the hardware do
// this at all", so the log is the deliverable of the first device round.
static int sLoggedAnchors = 0;
static int sPollCount = 0;

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
void sm64_vr_hands_register_device(void *gcController) {
    GCController *c = (__bridge GCController *)gcController;
    if (c == nil) { return; }
    if (@available(visionOS 26.0, *)) {
        ar_accessory_load_from_device(c,
            ^(id<GCDevice> device, bool successful, ar_error_t error, ar_accessory_t accessory) {
                (void)device;
                if (!successful || accessory == NULL) {
                    // THE ANSWER, if it is no. Logged at the same volume as the
                    // success case so a device round cannot be ambiguous about it.
                    NSLog(@"[vrhands] accessory load FAILED for '%@' (category '%@') — "
                           "no per-hand pose from this device%@",
                          c.vendorName, c.productCategory,
                          error ? @"" : @" (no error object)");
                    return;
                }
                if (sAccessoryCount >= SM64_VR_MAX_ACCESSORIES) {
                    NSLog(@"[vrhands] accessory table full — ignoring '%s'",
                          ar_accessory_get_name(accessory));
                    return;
                }
                ar_accessory_chirality_t ch = ar_accessory_get_inherent_chirality(accessory);
                sAccessory[sAccessoryCount] = accessory;
                sAccessoryDevice[sAccessoryCount] = c;
                sAccessoryCount++;
                sProviderDirty = true;
                NSLog(@"[vrhands] accessory LOADED: '%s' chirality=%s from '%@' (category '%@') "
                       "— %d accessory(s) known",
                      ar_accessory_get_name(accessory),
                      ch == ar_accessory_chirality_left  ? "left"
                    : ch == ar_accessory_chirality_right ? "right" : "unspecified",
                      c.vendorName, c.productCategory, sAccessoryCount);
            });
    }
}

void sm64_vr_hands_forget_device(void *gcController) {
    GCController *c = (__bridge GCController *)gcController;
    if (c == nil) { return; }
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessoryDevice[i] != c) { continue; }
        for (int j = i; j < sAccessoryCount - 1; j++) {
            sAccessory[j] = sAccessory[j + 1];
            sAccessoryDevice[j] = sAccessoryDevice[j + 1];
        }
        sAccessoryCount--;
        sAccessory[sAccessoryCount] = NULL;
        sAccessoryDevice[sAccessoryCount] = nil;
        sProviderDirty = true;
        // Drop the poses with the device, or a hand freezes mid-air where the
        // controller was when it vanished — the donor's "release everything on
        // focus loss" rule, applied to geometry instead of buttons.
        sHandValid[0] = sHandValid[1] = 0;
        NSLog(@"[vrhands] accessory device disconnected — %d left", sAccessoryCount);
        return;
    }
}

// ---------------------------------------------------------------------------
// Provider lifecycle
// ---------------------------------------------------------------------------
API_AVAILABLE(visionos(26.0))
static void sm64_vr_hands_rebuild_provider(void) {
    sProviderDirty = false;
    sProvider = NULL;
    sSession = NULL;
    sHandValid[0] = sHandValid[1] = 0;
    if (sAccessoryCount == 0) { return; }

    ar_accessories_t set = ar_accessories_create();
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessory[i] != NULL) { ar_accessories_add_accessory(set, sAccessory[i]); }
    }
    ar_accessory_tracking_configuration_t cfg = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(cfg, set);

    sProvider = ar_accessory_tracking_provider_create(cfg);
    sSession  = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(sProvider, NULL);
    ar_session_run(sSession, providers);
    NSLog(@"[vrhands] accessory tracking session running with %d accessory(s)", sAccessoryCount);
}

// ---------------------------------------------------------------------------
// Per-frame poll
// ---------------------------------------------------------------------------
void sm64_vr_hands_poll(void) {
    if (@available(visionOS 26.0, *)) {
        if (sProviderDirty) { sm64_vr_hands_rebuild_provider(); }
        if (sProvider == NULL) { return; }

        ar_accessory_anchors_t anchors =
            ar_accessory_tracking_provider_get_latest_anchors(sProvider);
        if (anchors == NULL) { return; }

        size_t n = ar_accessory_anchors_get_count(anchors);
        // A bitmask rather than an array: a block cannot capture a C array, and
        // two loose ints would need two __block slots to say one thing.
        __block int seenMask = 0;
        __block int logThis = 0;
        // Log the first few polls and then every ~10 seconds at 90 Hz, so the
        // log answers "did it ever work" and "is it still working" without
        // drowning the device console.
        if (sLoggedAnchors < 5 || (sPollCount % 900) == 0) { logThis = 1; sLoggedAnchors++; }
        sPollCount++;
        if (logThis) { NSLog(@"[vrhands] poll: %zu anchor(s)", n); }

        ar_accessory_anchors_enumerate_anchors(anchors, ^bool(ar_accessory_anchor_t anchor) {
            bool tracked = ar_accessory_anchor_is_tracked(anchor);
            ar_accessory_chirality_t ch = ar_accessory_anchor_get_held_chirality(anchor);
            simd_float4x4 xf = ar_accessory_anchor_get_origin_from_anchor_transform(anchor);
            if (logThis) {
                NSLog(@"[vrhands]   anchor tracked=%d held=%d chirality=%s pos=(%.3f, %.3f, %.3f)",
                      tracked, ar_accessory_anchor_is_held(anchor),
                      ch == ar_accessory_chirality_left  ? "left"
                    : ch == ar_accessory_chirality_right ? "right" : "unspecified",
                      (double)xf.columns[3].x, (double)xf.columns[3].y, (double)xf.columns[3].z);
            }
            if (!tracked) { return true; }
            // Chirality can be unspecified (a controller resting on a table has
            // no hand). Fall back to the accessory's INHERENT chirality, which a
            // left/right pair always has, rather than guessing from position.
            int hand = -1;
            if (ch == ar_accessory_chirality_left)  { hand = SM64_VR_HAND_LEFT;  }
            else if (ch == ar_accessory_chirality_right) { hand = SM64_VR_HAND_RIGHT; }
            else {
                ar_accessory_t acc = ar_accessory_anchor_get_accessory(anchor);
                if (acc != NULL) {
                    ar_accessory_chirality_t inh = ar_accessory_get_inherent_chirality(acc);
                    if (inh == ar_accessory_chirality_left)  { hand = SM64_VR_HAND_LEFT;  }
                    if (inh == ar_accessory_chirality_right) { hand = SM64_VR_HAND_RIGHT; }
                }
            }
            if (hand < 0) { return true; }
            sHandWorld[hand] = xf;
            sHandValid[hand] = 1;
            seenMask |= (1 << hand);
            return true;
        });

        // Anything not seen this poll stops being drawn, rather than lingering
        // at its last pose.
        for (int h = 0; h < 2; h++) { if (!(seenMask & (1 << h))) { sHandValid[h] = 0; } }
    }
}

// ---------------------------------------------------------------------------
// Query
// ---------------------------------------------------------------------------
int sm64_vr_hands_active(void) {
    if (!sHandsEnabled) { return 0; }
    if (!sm64_vr_first_person_active()) { return 0; }  // your hands belong where your body is
    return (sHandValid[0] || sHandValid[1]) ? 1 : 0;
}

int sm64_vr_hand_matrix(int hand, float out[4][4]) {
    if (hand < 0 || hand > 1 || !sHandValid[hand] || !sHandsEnabled) { return 0; }

    float camFromWorld[16];
    if (!sm64_vr_camera_from_world(camFromWorld)) { return 0; }

    simd_float4x4 CfW;
    memcpy(&CfW, camFromWorld, sizeof(CfW));

    simd_float4x4 M = simd_mul(CfW, sHandWorld[hand]);

    // Mario's hand geometry is in HIS units, and camera space is game units, so
    // the only scaling wanted is the taste knob. Applied on the right so it
    // scales the model about its own origin rather than sliding it along the
    // camera axes.
    if (sHandScale != 1.0f) {
        simd_float4x4 S = matrix_identity_float4x4;
        S.columns[0].x = S.columns[1].y = S.columns[2].z = sHandScale;
        M = simd_mul(M, S);
    }

    // simd stores column-major, which IS fast3d's row-vector layout read straight
    // through — the same identity the EyeVP publish relies on.
    memcpy(out, &M, sizeof(simd_float4x4));
    return 1;
}

void  sm64_vr_hands_set_enabled(int on) { sHandsEnabled = on ? 1 : 0; }
int   sm64_vr_hands_get_enabled(void)   { return sHandsEnabled; }
void  sm64_vr_hands_set_scale(float s)  { if (s >= 0.1f && s <= 10.0f) { sHandScale = s; } }
float sm64_vr_hands_get_scale(void)     { return sHandScale; }

#endif // SM64_VISION_3D
