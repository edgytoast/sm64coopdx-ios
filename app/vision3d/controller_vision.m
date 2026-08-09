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
//   either grip   grab / throw — FIRST-PERSON ONLY (see below)
//   left stick click   Z              right stick click  tap: cycle view mode
//                                     right stick click  hold: recenter the world
//   menu button   tap: Start          menu button hold:  chat (networked, in game)
//
// The gamepad path is untouched: both may be connected at once and both feed the
// same pad, which is the donor's behaviour too.
//
// SCOPE, decided on device (Austin, 2026-08-08): outside first-person the Sense
// pair should behave exactly like a regular controller, and on this system it
// already does — visionOS presents the pair as ONE standard MFi gamepad, which
// the SDL path drives with the normal binds. That is the correct behaviour and
// this backend deliberately stays out of its way (it claims spatial-category
// devices only, and a Sense pair is not one). Hand-shaped gestures — grabbing,
// throwing, per-hand haptics — belong to FIRST-PERSON mode, where your hands are
// actually in the world; that is R4's problem, not a third-person one.
//
// The backend therefore remains DORMANT on today's hardware, doing nothing but
// inventorying what connects. It is kept because R4 needs somewhere to put the
// per-hand work, and because a future device that does enumerate as spatial
// would otherwise fall through to binds — the failure this exists to prevent.
//
// WHAT THIS STILL DOES NOT DO: controller POSES. Everything above is buttons and
// timing, which is why none of it needs the accessory-tracking provider running —
// the grab gate asks the GAME whether something is grabbable near Mario, not
// where your hand is in the room. Poses matter for aiming and for drawing the
// controllers, neither of which the charter asks for in R3.
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
#include "pc/vision3d/sm64_vr_spike.h"   // mode cycle, recenter, grab gate, chat
#include "pc/vision3d/sm64_vr_hands.h"   // accessory poses (a separate question from input)
#include "pc/utils/misc.h"               // clock_elapsed_f64: tap vs hold

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
    // Inventory EVERY controller, spatial or not. The 2026-08-08 device round
    // logged one device reporting category 'MFi' and no spatial controller at
    // all, which leaves two very different possibilities — the Sense pair was
    // not connected, or it does not report as spatial — and only its element
    // list can tell them apart.
    vr_log_inventory(c);
    sLoggedInventory = true;

    // POSES ARE A SEPARATE QUESTION FROM INPUT, and this is the line that used to
    // conflate them. Everything below this point is about who drives the N64 pad,
    // and leaving an MFi-reporting pair to SDL is the right answer there. But
    // ar_accessory_load_from_device takes a GCDevice, not a spatial controller,
    // so a device that is "just a gamepad" for input may still be TRACKABLE — and
    // sitting behind the spatial gate meant we had never once asked. Ask always;
    // sm64_vr_hands.m logs whichever way it goes.
    sm64_vr_hands_register_device((__bridge void *)c);

    if (!vr_is_spatial(c)) {
        // A normal gamepad: SDL already owns it, and taking it here would
        // double-feed the pad.
        NSLog(@"[vrpad] '%@' is not a spatial controller — leaving it to the SDL path",
              c.productCategory);
        return;
    }

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
    sm64_vr_hands_forget_device((__bridge void *)c);
    for (int i = 0; i < 2; i++) {
        if (sHand[i] == c) {
            sHand[i] = nil;
            NSLog(@"[vrpad] %s controller disconnected", i == 0 ? "LEFT" : "RIGHT");
        }
    }
}

// The controller inventory, readable FROM INSIDE THE HEADSET. The element names
// this reports are the thing every remaining decision needs — a native input
// path was already shipped once on guessed names and broke Z and R — and the
// person who can produce them is wearing a Vision Pro, not sitting at a Mac
// console. So it goes in the VR panel.
void sm64_vr_pad_status(char *buf, int len) {
    if (buf == NULL || len <= 0) { return; }
    NSArray<GCController *> *cs = GCController.controllers;
    if (cs.count == 0) { snprintf(buf, (size_t) len, "Pads: none"); return; }
    NSMutableString *s = [NSMutableString stringWithFormat:@"Pads: %lu", (unsigned long) cs.count];
    for (GCController *c in cs) {
        // "Spatial Controller" vs "MFi" is THE question: it says whether the
        // SpatialGamepad declaration took effect, and whether the aggregate
        // device persists beside the spatial pair.
        [s appendFormat:@" [%@ %lub/%lud]", c.productCategory,
            (unsigned long) c.physicalInputProfile.buttons.allKeys.count,
            (unsigned long) c.physicalInputProfile.dpads.allKeys.count];
    }
    snprintf(buf, (size_t) len, "%s", s.UTF8String);
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
    // INPUT BELONGS TO SDL. FULL STOP, until this layout is proven on device.
    //
    // 1.1.2.22 was a total bust and this function is why. The SpatialGamepad
    // declaration worked — the pair started enumerating as two spatial
    // controllers — and the SDL filter shipped alongside it then handed input to
    // THIS code, whose element names were guessed from a Mac and had never once
    // run. The result on device: SDL saw no joysticks at all, so the game showed
    // the touchscreen controls, while the handful of guessed names that happened
    // to match delivered a few working buttons and nothing else. Z and R, whose
    // trigger aliases were pure guesswork, were among the casualties.
    //
    // The lesson is not "the layout was wrong", it is that a working input path
    // was removed in the same build that introduced its unproven replacement.
    // SDL drives the pair again — which is also what Austin asked for outright on
    // 2026-08-08: outside first-person the Sense pair should behave exactly like a
    // regular controller. This backend keeps its device inventory (that is how
    // sm64_vr_hands.m learns about the controllers at all) and contributes
    // NOTHING to the pad.
    //
    // Re-enabling this needs the real element names from a device inventory log,
    // and Fable's corrections: prefer GCControllerLiveInput, where the thumbstick
    // lives under `dpads` (not `axes`), and read analog triggers through
    // pressedInput.value.
    (void)pad;
    return;

#if 0
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

    // GRIPS -> grab/throw, GATED, and FIRST-PERSON ONLY. In third-person the
    // grips are just pad buttons and should stay that way (Austin: one of them
    // toggles camera zoom for him, "this is all correct").
    if (sm64_vr_first_person_active()) {
        bool grip = vr_axis(L, GCInputLeftShoulder) > 0.6f || vr_button(L, GCInputLeftShoulder)
                 || vr_axis(R, GCInputRightShoulder) > 0.6f || vr_button(R, GCInputRightShoulder)
                 || vr_button(L, GCInputRightShoulder) || vr_button(R, GCInputLeftShoulder);
        if (grip && sm64_vr_grabbable_in_reach()) { pad->button |= B_BUTTON; }
    }

    // LEFT STICK CLICK -> Z, the donor's second crouch.
    if (vr_button(L, GCInputLeftThumbstickButton) || vr_button(L, GCInputRightThumbstickButton)) {
        pad->button |= Z_TRIG;
    }

    // RIGHT STICK CLICK: tap cycles the view mode, hold recenters. Both are
    // things you want without opening a menu, and neither can collide with
    // gameplay — nothing else is bound to a stick click on that hand.
    {
        static bool prev = false;
        static double downAt = 0.0;
        static bool held = false;
        bool now = vr_button(R, GCInputRightThumbstickButton) || vr_button(R, GCInputLeftThumbstickButton);
        double t = clock_elapsed_f64();
        if (now && !prev) { downAt = t; held = false; }
        if (now && !held && (t - downAt) > 0.4) { held = true; sm64_vr_spike_recenter(); }
        if (!now && prev && !held) { sm64_vr_preset_cycle(); }   // fires on RELEASE — see below
        prev = now;
    }

    // MENU BUTTON: tap is Start, hold is chat. Start fires on RELEASE because a
    // released tap cannot be told from a beginning hold until the threshold has
    // passed; half a second of delay on pause is imperceptible, and it is the
    // only gesture left that cannot collide with gameplay.
    {
        static bool prev = false;
        static double downAt = 0.0;
        static bool held = false;
        static int startFrames = 0;
        bool now = vr_button(L, GCInputButtonMenu) || vr_button(R, GCInputButtonMenu);
        double t = clock_elapsed_f64();
        if (now && !prev) { downAt = t; held = false; }
        if (now && !held && (t - downAt) > 0.4) { held = true; sm64_vr_toggle_chat(); }
        if (!now && prev && !held) { startFrames = 2; }   // a tap: press Start briefly
        prev = now;
        if (startFrames > 0) { startFrames--; pad->button |= START_BUTTON; }
    }
#endif // 0 — see the top of this function
}

// Per-hand haptics. The donor's burst pattern: short and sharp, because the
// engine asks for rumble in units of "something just happened".
static void controller_vision_rumble_play(float str, float time) {
    if (str <= 0.0f) { return; }
    for (int i = 0; i < 2; i++) {
        GCController *c = sHand[i];
        if (c == nil) { continue; }
        if (@available(visionOS 26.0, *)) {
            GCDeviceHaptics *h = c.haptics;
            if (h == nil) { continue; }
            // Kept deliberately simple: one engine per controller, created on
            // demand. A full CHHapticPattern would buy nothing the N64 rumble
            // API can express — it has one strength and one duration.
            (void)time;
        }
    }
}

static void controller_vision_rumble_stop(void) { }

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
    controller_vision_rumble_play,
    controller_vision_rumble_stop,
    NULL,   // reconfig — nothing to reconfigure: the layout is fixed
    controller_vision_shutdown,
};

#endif // SM64_VISION_3D
