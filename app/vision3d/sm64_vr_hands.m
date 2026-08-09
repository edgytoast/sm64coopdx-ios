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

// The toggle and the size live in the SHARED settings store, not in statics
// here, so the visionOS sheet and the in-game DJUI panel drive one value —
// the same one-store rule the rest of the VR settings follow.
static int sm64_vr_hands_enabled(void) {
    return sm64_3d_setting_f("vrHands", SM64_DEF_VRHANDS) > 0.5f;
}
static float sm64_vr_hands_scale(void) {
    float s = sm64_3d_setting_f("vrHandSize", SM64_DEF_VRHANDSIZE);
    return (s >= 0.1f && s <= 10.0f) ? s : SM64_DEF_VRHANDSIZE;
}

// Diagnostics: this is a feature whose first question is "does the hardware do
// this at all", so the log is the deliverable of the first device round.
static int sLoggedAnchors = 0;
static int sPollCount = 0;

// ...and the log is the WRONG place for the answer when the person who can run
// the headset is not the person reading a Mac console. These four counters are
// surfaced as a row in the VR panel so the answer is readable in-headset:
//   loads 0            -> the accessory load never even completed
//   fails > 0          -> ARKit refused this device; hands are impossible here
//   loads > 0, polls 0 -> the provider never ran
//   polls > 0, anchors 0 -> tracking runs but reports nothing held
static int sLoadOK = 0;
static int sLoadFail = 0;
static int sLastAnchorCount = 0;
static int sLoadFailCode = 0;   // ar_error code from the last failed load

// Authorization. THE BUG behind "N devices NOT trackable" on 1.1.2.19: nothing
// ever called ar_session_request_authorization, so accessory tracking was never
// permitted and — the tell Austin spotted — no permission row ever appeared in
// visionOS Settings. A load attempted without that authorization fails, and it
// fails in exactly the same shape as "this device cannot be tracked", which is
// why the first read of the status line was so misleading.
//
// So: request FIRST, load after. Devices that connect before the answer arrives
// are parked in sPending and loaded when it does.
static int  sAuthState = 0;   // 0 = not asked / pending, 1 = allowed, -1 = denied
static bool sAuthAsked = false;
static GCController *sPending[SM64_VR_MAX_ACCESSORIES];
static int  sPendingCount = 0;

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
API_AVAILABLE(visionos(26.0))
static void hands_load_device_retry(GCController *c, int attempt);

API_AVAILABLE(visionos(26.0))
static void hands_load_device(GCController *c) { hands_load_device_retry(c, 0); }

API_AVAILABLE(visionos(26.0))
static void hands_load_device_retry(GCController *c, int attempt) {
    if (c == nil) { return; }
    // Dedupe (Fable 2b): a device can arrive twice — once queued behind the
    // authorization prompt and again from a later didConnect on a focus change.
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessoryDevice[i] == c) { return; }
    }
    ar_accessory_load_from_device(c,
        ^(id<GCDevice> device, bool successful, ar_error_t error, ar_accessory_t accessory) {
            (void)device;
            if (!successful || accessory == NULL) {
                sLoadFail++;
                // The ERROR CODE, captured rather than summarised. 1200 is
                // ar_accessory_tracking_error_code_accessory_loading_failed, the
                // only code the accessory header documents; anything else is a
                // fact worth having. Surfaced in the status line too, because the
                // headset is where this gets read.
                long code = -1;
                CFStringRef desc = NULL;
                if (error != NULL) {
                    code = (long) ar_error_get_error_code(error);
                    CFErrorRef cfe = ar_error_copy_cf_error(error);
                    if (cfe != NULL) { desc = CFErrorCopyDescription(cfe); CFRelease(cfe); }
                }
                sLoadFailCode = (int) code;
                NSLog(@"[vrhands] accessory load FAILED for '%@' (category '%@') "
                       "code=%ld attempt=%d desc=%@",
                      c.vendorName, c.productCategory, code, attempt,
                      desc ? (__bridge NSString *)desc : @"(none)");
                if (desc != NULL) { CFRelease(desc); }
                // ONE retry, 2s later (Fable 2c): accessory tracking is gated on
                // the app being focused, and a load issued during entry or a
                // focus change can fail for that alone. Cheap insurance, and
                // both results are logged so a retry cannot hide the first.
                if (attempt == 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (@available(visionOS 26.0, *)) { hands_load_device_retry(c, 1); }
                    });
                }
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
            sLoadOK++;
            sProviderDirty = true;
            NSLog(@"[vrhands] accessory LOADED: '%s' chirality=%s from '%@' (category '%@') "
                   "— %d accessory(s) known",
                  ar_accessory_get_name(accessory),
                  ch == ar_accessory_chirality_left  ? "left"
                : ch == ar_accessory_chirality_right ? "right" : "unspecified",
                  c.vendorName, c.productCategory, sAccessoryCount);
        });
}

// Ask once, then drain whatever queued up while the user was deciding.
API_AVAILABLE(visionos(26.0))
static void hands_request_authorization(void) {
    if (sAuthAsked) { return; }
    sAuthAsked = true;
    if (sSession == NULL) { sSession = ar_session_create(); }
    NSLog(@"[vrhands] requesting accessory-tracking authorization");
    ar_session_request_authorization(sSession, ar_authorization_type_accessory_tracking,
        ^(ar_authorization_results_t results, ar_error_t error) {
            __block int state = -1;
            if (results != NULL) {
                ar_authorization_results_enumerate_results(results,
                    ^bool(ar_authorization_result_t r) {
                        if (ar_authorization_result_get_authorization_type(r)
                                == ar_authorization_type_accessory_tracking) {
                            state = (ar_authorization_result_get_status(r)
                                     == ar_authorization_status_allowed) ? 1 : -1;
                        }
                        return true;
                    });
            }
            sAuthState = state;
            NSLog(@"[vrhands] accessory-tracking authorization: %s%@",
                  state == 1 ? "ALLOWED" : "DENIED", error ? @" (with error)" : @"");
            if (state != 1) { return; }
            for (int i = 0; i < sPendingCount; i++) { hands_load_device(sPending[i]); }
            sPendingCount = 0;
        });
}

void sm64_vr_hands_register_device(void *gcController) {
    GCController *c = (__bridge GCController *)gcController;
    if (c == nil) { return; }
    if (@available(visionOS 26.0, *)) {
        hands_request_authorization();
        if (sAuthState == 1) { hands_load_device(c); return; }
        if (sAuthState == -1) { return; }   // denied: loading would only fail
        if (sPendingCount < SM64_VR_MAX_ACCESSORIES) { sPending[sPendingCount++] = c; }
    }
}

void sm64_vr_hands_forget_device(void *gcController) {
    GCController *c = (__bridge GCController *)gcController;
    if (c == nil) { return; }
    for (int i = 0; i < sPendingCount; i++) {
        if (sPending[i] != c) { continue; }
        for (int j = i; j < sPendingCount - 1; j++) { sPending[j] = sPending[j + 1]; }
        sPending[--sPendingCount] = nil;
        break;
    }
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
    sHandValid[0] = sHandValid[1] = 0;
    if (sAccessoryCount == 0) { return; }

    ar_accessories_t set = ar_accessories_create();
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessory[i] != NULL) { ar_accessories_add_accessory(set, sAccessory[i]); }
    }
    ar_accessory_tracking_configuration_t cfg = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(cfg, set);

    // The SAME session the authorization was granted on — a fresh one would be
    // unauthorized again.
    if (sSession == NULL) { sSession = ar_session_create(); }
    sProvider = ar_accessory_tracking_provider_create(cfg);
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
        sLastAnchorCount = (int) n;
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
    if (!sm64_vr_hands_enabled()) { return 0; }
    if (!sm64_vr_first_person_active()) { return 0; }  // your hands belong where your body is
    return (sHandValid[0] || sHandValid[1]) ? 1 : 0;
}

int sm64_vr_hand_matrix(int hand, float out[4][4]) {
    if (hand < 0 || hand > 1 || !sHandValid[hand] || !sm64_vr_hands_enabled()) { return 0; }

    float camFromWorld[16];
    if (!sm64_vr_camera_from_world(camFromWorld)) { return 0; }

    simd_float4x4 CfW;
    memcpy(&CfW, camFromWorld, sizeof(CfW));

    simd_float4x4 M = simd_mul(CfW, sHandWorld[hand]);

    // Mario's hand geometry is in HIS units, and camera space is game units, so
    // the only scaling wanted is the taste knob. Applied on the right so it
    // scales the model about its own origin rather than sliding it along the
    // camera axes.
    const float handScale = sm64_vr_hands_scale();
    if (handScale != 1.0f) {
        simd_float4x4 S = matrix_identity_float4x4;
        S.columns[0].x = S.columns[1].y = S.columns[2].z = handScale;
        M = simd_mul(M, S);
    }

    // simd stores column-major, which IS fast3d's row-vector layout read straight
    // through — the same identity the EyeVP publish relies on.
    memcpy(out, &M, sizeof(simd_float4x4));
    return 1;
}

// One line for the VR panel, so the answer is readable in the headset rather
// than only in a Mac console.
void sm64_vr_hands_status(char *buf, int len) {
    if (buf == NULL || len <= 0) { return; }
    if (sAuthState == -1) {
        snprintf(buf, (size_t) len, "Hands: permission DENIED");
    } else if (sAuthState == 0) {
        snprintf(buf, (size_t) len, "Hands: awaiting permission%s",
                 sAuthAsked ? "" : " (not asked)");
    } else if (sLoadOK == 0 && sLoadFail == 0) {
        snprintf(buf, (size_t) len, "Hands: allowed, no controller seen");
    } else if (sLoadOK == 0) {
        snprintf(buf, (size_t) len, "Hands: allowed, %d fail (err %d) of %d dev",
                 sLoadFail, sLoadFailCode, sAccessoryCount + sLoadFail);
    } else {
        snprintf(buf, (size_t) len, "Hands: %d loaded, %d anchor(s), %s%s",
                 sLoadOK, sLastAnchorCount,
                 sHandValid[0] ? "L" : "-", sHandValid[1] ? "R" : "-");
    }
}

int   sm64_vr_hands_get_enabled(void) { return sm64_vr_hands_enabled(); }
float sm64_vr_hands_get_scale(void)   { return sm64_vr_hands_scale(); }

#endif // SM64_VISION_3D
