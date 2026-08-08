// controller_vision.m — PSVR2 Sense controllers as an N64 pad (charter R3 / A10).
//
// A ControllerAPI backend registered beside controller_sdl, exactly as the donor
// registers theirs beside sdl/touchscreen. It fills the same OSContPad every
// other backend fills, which is why gameplay AND the DJUI menus work through it
// with nothing else plumbed: game_init.c reads that one pad for both.
//
// THE LAYOUT IS FIXED, AND THAT IS THE POINT (donor controller_vr.c:1-31).
// Sense inputs map straight to N64 buttons and deliberately do NOT go through
// the gamepad bind system. Gamepad binds carry personal flat-screen muscle
// memory — a punch rebound onto another face button, say — and inheriting that
// scrambles VR controllers in ways that read as wrong-hand bugs. Their ledger
// paid for that lesson; we are not paying it again.
//
//   left stick    move                right stick   camera
//   A             jump (A)            B             punch (B)
//   left trigger  crouch (Z)          right trigger R
//   menu/options  Start
//
// The gamepad path is untouched: both may be connected at once and both feed the
// same pad, which is the donor's behaviour too.
//
// WHAT THIS STAGE DOES NOT DO YET: poses, per-hand haptics, and the grab-gated
// grips. Those need the accessory-tracking provider running on the ARKit session
// and are the next step — buttons and sticks are what make the game playable,
// and they are what a first device round can actually verify.
//
// HANDEDNESS comes from ARKit, not GameController: GCDevice exposes no
// handedness, and ar_accessory_load_from_device -> inherent chirality is the
// documented pairing. It is asynchronous, so a controller is UNASSIGNED until
// its chirality lands; until then it drives nothing, which is better than
// guessing and giving someone a left stick that steers the camera.

#import "sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ARKit/ARKit.h>

#include <ultra64.h>
#include "pc/controller/controller_api.h"
#include "pc/vision3d/controller_vision.h"

// Assigned by chirality once ARKit answers. Weak-ish by convention: the connect
// notification owns the lifetime, and disconnect clears these.
static GCController *sHand[2];       // 0 = left, 1 = right
static bool sLoggedInventory = false;

// ---------------------------------------------------------------------------
// Element lookup. Spatial controllers are NOT extendedGamepad devices, so we go
// through physicalInputProfile by alias. The inventory is logged once per
// controller: the first device run tells us exactly what a Sense exposes, which
// beats guessing at names from a Mac.
// ---------------------------------------------------------------------------
static float vr_axis(GCController *c, NSString *name) {
    if (c == nil) { return 0.0f; }
    GCControllerAxisInput *a = c.physicalInputProfile.axes[name];
    return a ? a.value : 0.0f;
}

static bool vr_button(GCController *c, NSString *name) {
    if (c == nil) { return false; }
    GCControllerButtonInput *b = c.physicalInputProfile.buttons[name];
    return b ? b.isPressed : false;
}

static void vr_stick(GCController *c, NSString *name, float *outX, float *outY) {
    *outX = 0.0f; *outY = 0.0f;
    if (c == nil) { return; }
    GCControllerDirectionPad *d = c.physicalInputProfile.dpads[name];
    if (d == nil) { return; }
    *outX = d.xAxis.value;
    *outY = d.yAxis.value;
}

static void vr_log_inventory(GCController *c) {
    NSLog(@"[vrpad] controller '%@' category='%@' vendor='%@'",
          c.productCategory, c.productCategory, c.vendorName);
    NSLog(@"[vrpad]   buttons: %@", c.physicalInputProfile.buttons.allKeys);
    NSLog(@"[vrpad]   axes:    %@", c.physicalInputProfile.axes.allKeys);
    NSLog(@"[vrpad]   dpads:   %@", c.physicalInputProfile.dpads.allKeys);
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------
static bool vr_is_spatial(GCController *c) {
    if (@available(visionOS 26.0, *)) {
        return [c.productCategory isEqualToString:GCProductCategorySpatialController];
    }
    return false;
}

static void vr_adopt(GCController *c) {
    if (!vr_is_spatial(c)) {
        // A normal gamepad: SDL already owns it, and taking it here would
        // double-feed the pad. Logged so "my controller does nothing" is never a
        // mystery.
        NSLog(@"[vrpad] ignoring non-spatial controller '%@' (the SDL path owns it)",
              c.productCategory);
        return;
    }
    if (!sLoggedInventory) { vr_log_inventory(c); sLoggedInventory = true; }

    // Chirality via ARKit — see the file header for why not GameController.
    if (@available(visionOS 26.0, *)) {
        ar_accessory_load_from_device(c,
            ^(id<GCDevice> device, bool successful, ar_error_t error, ar_accessory_t accessory) {
                (void)device; (void)error;
                if (!successful || accessory == NULL) {
                    NSLog(@"[vrpad] accessory load failed — controller left unassigned");
                    return;
                }
                ar_accessory_chirality_t ch = ar_accessory_get_inherent_chirality(accessory);
                if (ch == ar_accessory_chirality_left) {
                    sHand[0] = c;
                    NSLog(@"[vrpad] LEFT controller assigned ('%s')", ar_accessory_get_name(accessory));
                } else if (ch == ar_accessory_chirality_right) {
                    sHand[1] = c;
                    NSLog(@"[vrpad] RIGHT controller assigned ('%s')", ar_accessory_get_name(accessory));
                } else {
                    NSLog(@"[vrpad] controller reports UNSPECIFIED chirality — left unassigned");
                }
            });
    }
}

static void vr_forget(GCController *c) {
    for (int i = 0; i < 2; i++) {
        if (sHand[i] == c) {
            sHand[i] = nil;
            NSLog(@"[vrpad] %s controller disconnected", i == 0 ? "LEFT" : "RIGHT");
        }
    }
}

// ---------------------------------------------------------------------------
// ControllerAPI
// ---------------------------------------------------------------------------
static void controller_vision_init(void) {
    for (GCController *c in GCController.controllers) { vr_adopt(c); }
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            vr_adopt((GCController *)n.object);
        }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            vr_forget((GCController *)n.object);
        }];
    NSLog(@"[vrpad] spatial-controller backend ready (%lu controller(s) present)",
          (unsigned long)GCController.controllers.count);
}

// The N64 stick is signed 8-bit; the game's own deadzone handling lives
// downstream, so this only converts.
static s8 vr_to_stick(float v) {
    float s = v * 127.0f;
    if (s >  127.0f) { s =  127.0f; }
    if (s < -127.0f) { s = -127.0f; }
    return (s8)s;
}

static void controller_vision_read(OSContPad *pad) {
    GCController *L = sHand[0], *R = sHand[1];
    if (L == nil && R == nil) { return; }   // nothing held: report nothing, hold nothing

    float lx, ly, rx, ry;
    vr_stick(L, GCInputThumbstick, &lx, &ly);
    vr_stick(R, GCInputThumbstick, &rx, &ry);

    // MOVE. |= and max() rather than assignment, so a gamepad held in the other
    // hand still works — both feed one pad (donor precedent).
    s8 mx = vr_to_stick(lx), my = vr_to_stick(ly);
    if (mx != 0) { pad->stick_x = mx; }
    if (my != 0) { pad->stick_y = my; }

    // CAMERA. The C buttons are what the game's own camera reads on a pad; the
    // analog ext_stick carries the finer movement for the modes that use it.
    if (rx < -0.5f) { pad->button |= L_CBUTTONS; }
    if (rx >  0.5f) { pad->button |= R_CBUTTONS; }
    if (ry >  0.5f) { pad->button |= U_CBUTTONS; }
    if (ry < -0.5f) { pad->button |= D_CBUTTONS; }
    s8 cx = vr_to_stick(rx), cy = vr_to_stick(ry);
    if (cx != 0) { pad->ext_stick_x = cx; }
    if (cy != 0) { pad->ext_stick_y = cy; }

    // FACE BUTTONS. Tried under several aliases because a Sense is not an
    // extendedGamepad and the first device run is what tells us its real names —
    // the inventory log above is the instrument for that.
    if (vr_button(R, GCInputButtonA) || vr_button(R, GCInputButtonB)) { pad->button |= A_BUTTON; }
    if (vr_button(R, GCInputButtonX) || vr_button(R, GCInputButtonY)) { pad->button |= B_BUTTON; }
    if (vr_button(L, GCInputButtonA) || vr_button(L, GCInputButtonX)) { pad->button |= B_BUTTON; }

    // TRIGGERS: left crouches (Z), right is R.
    if (vr_axis(L, GCInputLeftTrigger)  > 0.6f || vr_button(L, GCInputLeftTrigger))  { pad->button |= Z_TRIG; }
    if (vr_axis(L, GCInputRightTrigger) > 0.6f || vr_button(L, GCInputRightTrigger)) { pad->button |= Z_TRIG; }
    if (vr_axis(R, GCInputLeftTrigger)  > 0.6f || vr_button(R, GCInputLeftTrigger))  { pad->button |= R_TRIG; }
    if (vr_axis(R, GCInputRightTrigger) > 0.6f || vr_button(R, GCInputRightTrigger)) { pad->button |= R_TRIG; }

    // START from either menu button.
    if (vr_button(L, GCInputButtonMenu) || vr_button(R, GCInputButtonMenu)) { pad->button |= START_BUTTON; }
}

// Bind capture deliberately gets nothing: the layout is fixed, so there is
// nothing here to rebind (donor's rule, and the reason it exists).
static u32 controller_vision_rawkey(void) { return VK_INVALID; }

static void controller_vision_shutdown(void) {
    sHand[0] = sHand[1] = nil;
}

struct ControllerAPI controller_vision = {
    VK_INVALID,
    controller_vision_init,
    controller_vision_read,
    controller_vision_rawkey,
    NULL,   // rumble_play  — per-hand haptics land with the pose work
    NULL,   // rumble_stop
    NULL,   // reconfig     — nothing to reconfigure: the layout is fixed
    controller_vision_shutdown,
};

#endif // SM64_VISION_3D
