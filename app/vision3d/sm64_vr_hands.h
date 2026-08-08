// sm64_vr_hands.h — Mario's hands on your controllers (charter R4, Austin 2026-08-08).
//
// Pure C so gfx_pc.c can include it. The Objective-C / ARKit side lives in
// sm64_vr_hands.m; see the header comment there for what this actually costs.

#ifndef SM64_VR_HANDS_H
#define SM64_VR_HANDS_H

#define SM64_VR_HAND_LEFT  0
#define SM64_VR_HAND_RIGHT 1

// Registration from the controller backend. Takes a GCController as void* so
// this header stays free of GameController. Registering a device that has no
// trackable accessory is harmless — that IS the common case, and finding out is
// the point (see the MFi note in sm64_vr_hands.m).
void sm64_vr_hands_register_device(void *gcController);
void sm64_vr_hands_forget_device(void *gcController);

// Per-frame anchor poll. Compositor thread, called from the VR loop.
void sm64_vr_hands_poll(void);

// 1 while hands should be drawn: enabled, first-person, and at least one hand
// actually tracked this frame.
int sm64_vr_hands_active(void);

// The hand's model->CAMERA matrix in fast3d row-vector form (the space our EyeVP
// consumes). Returns 0 when that hand is not tracked, in which case nothing is
// drawn for it. The matrix is the same for both eyes — the eye difference lives
// entirely in EyeVP — so one display list serves both.
int sm64_vr_hand_matrix(int hand, float out[4][4]);

// The "Show Mario Hands" toggle and the hand-size multiplier, both read from the
// shared settings store (vrHands / vrHandSize) so the visionOS sheet and the
// in-game DJUI panel drive one value. Read-only here: writes go through
// sm64_3d_setting_set_f like every other VR setting. Turning hands off still
// leaves the pose poll running, so the log keeps answering whether the hardware
// can be tracked at all.
int   sm64_vr_hands_get_enabled(void);
float sm64_vr_hands_get_scale(void);

#endif // SM64_VR_HANDS_H
