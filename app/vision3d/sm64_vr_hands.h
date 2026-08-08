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

// Setting: "Show Mario Hands". Off means the poll still runs (so the log still
// tells us whether poses exist) but nothing is drawn.
void sm64_vr_hands_set_enabled(int on);
int  sm64_vr_hands_get_enabled(void);

// Hand size, as a multiplier on Mario's own hand geometry. 1.0 is Mario-sized,
// which is life-sized in first-person because that is what the FP world scale
// means. Exposed because "Mario-sized" and "your-hand-sized" are only the same
// thing if the world scale is exactly right.
void  sm64_vr_hands_set_scale(float s);
float sm64_vr_hands_get_scale(void);

#endif // SM64_VR_HANDS_H
