// sm64_vr_spike.m — R0 SPIKE, THROWAWAY. See sm64_vr_spike.h for the question
// this exists to answer (VR-CHARTER §5 R0.1 / A7).
//
// The minimum loop that can present, plus a contract dump. Everything about the
// loop SHAPE is copied deliberately from sm64_immersive.m rather than rewritten:
// pacing (cp_frame_predict_timing + cp_time_wait_until), a per-frame ARKit
// device anchor, a queue from the DRAWABLE's device, and cleared+stored depth
// are each individually load-bearing — a frame missing any of them is silently
// never displayed, which would read as "the style aborted" when it did not.

#import "sm64_vr_spike.h"

#ifdef SM64_VISION_3D

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

volatile int sm64_vr_spike_stop = 0;
volatile int sm64_vr_spike_running = 0;
volatile int sm64_vr_spike_variant = 0;

// ---------------------------------------------------------------------------
// R0.2 — the frozen-pose world (VR-CHARTER §5 R0.2 / A3).
//
// The compositor loop composes EyeVP = P * V * A once, from a device anchor
// captured ONCE, and publishes it; gfx_stereo_projection returns it instead of
// the game's projection for every perspective draw. Frozen on purpose: a live
// per-frame pose is R1, and separating the two means a wrong-looking world here
// is a MATRIX bug and never a pose-plumbing bug.
//
// THE CONVENTION BRIDGE, which is the whole risk in this file:
//   - simd is COLUMN-vector, column-major:  clip = M * p
//   - fast3d is ROW-vector:                 clip = v * M,  M[row][col]
//   A simd_float4x4 reinterpreted as a C float[4][4] indexed [i][j] yields
//   columns[i][j] — which IS the transpose. So memcpy of the composed simd
//   matrix into the fast3d array is the entire conversion, and the factors
//   multiply in the mirrored order (simd P*V*A  <=>  fast3d A*V*P), exactly the
//   donor's A * V * P.
// ---------------------------------------------------------------------------

// Donor "Diorama" preset (vr.c:1503) — now including the two comfort levers the
// first device build shipped WITHOUT, which is why it doubled (Austin,
// 2026-08-07: "VERY close up to my face and doubled, almost like I'm looking
// crosseyed"):
//
//   STEREO SCALE. The donor scales each eye's offset from the head centre
//   ("1.0 = true IPD, lower = gentler stereo / less cross-eye", vr.c:367) and
//   ships 0.50. Kept as a comfort slider — but 2026-08-07's device round proved
//   it is NOT what was doubling the view: at 0% the doubles were FURTHER apart,
//   which cannot happen if each eye's rotation and frustum agree (0% must give
//   two identical images). The real cause was the rebuilt frustum; see
//   sm64_vr_forward_z_projection. Default is 1.0, the true geometry.
//
//   STANDOFF. The donor keeps the anchor at least sClipMargin = 0.30 m from the
//   head (vr.c:288/519, the anti-clip's resting behaviour). At 0.25 m the world
//   is inside that margin before you even lean in.
//
// Live-tunable from the settings sheet, because the donor's own numbers are
// annotated "tuned by feel" and the headset is the only instrument that counts.
static float sVrScale  = 1376.0f; // game units per metre (bigger = smaller world)
static float sVrDist   = 0.60f;   // metres in front of the frozen head (donor 0.25, pushed out after the device report)
static float sVrHeight = -0.35f;  // metres relative to eye level
static float sVrStereo = 1.00f;   // eye offset as a fraction of the true IPD (1.0 = geometrically true)
static const float kVrClipMargin = 0.30f; // donor sClipMargin: minimum anchor standoff
static float sVrClipPush = 0.0f;          // the eased anti-clip pushback, metres

// Panel mode (charter A5), read by BOTH threads: the engine (whose VR accessors
// go NULL so the game renders its own flat projection) and this loop (which then
// draws that frame on a world-locked screen). Declared here because the eye
// sizer above needs it too — a menu renders at a screen's shape, not a view's.
static volatile int sVrPanelMode = 0;

// While the VR options panel itself is open we deliberately STAY in the stereo
// world (donor: djui_panel_is_vr_panel). Every slider in it describes the world,
// and you cannot judge a world you have just replaced with a menu screen. The
// menu rides the HUD plane instead — enlarged, because the donor's ledger has a
// whole entry about the VR panel rendering half-size on the gameplay HUD quad.
static volatile int sVrMenuOverWorld = 0;
void sm64_vr_spike_set_menu_over_world(int on) { sVrMenuOverWorld = on ? 1 : 0; }
int  sm64_vr_spike_menu_over_world(void) { return sVrMenuOverWorld; }

// Anti-clip handoff (charter R2). The loop publishes the cyclopean eye in
// game-camera space; the engine thread runs level collision on it and writes back
// an anchor offset in metres, which the next frame's placement applies.
static float sVrHeadCamPos[3] = { 0.0f, 0.0f, 0.0f };
static volatile int sVrHeadCamValid = 0;
static float sVrAnticlipOffset[3] = { 0.0f, 0.0f, 0.0f };

bool sm64_vr_anticlip_get_head_campos(float out[3]) {
    if (!sVrHeadCamValid || sVrPanelMode) { return false; }
    out[0] = sVrHeadCamPos[0]; out[1] = sVrHeadCamPos[1]; out[2] = sVrHeadCamPos[2];
    return true;
}

void sm64_vr_anticlip_set_offset(const float m[3]) {
    sVrAnticlipOffset[0] = m[0]; sVrAnticlipOffset[1] = m[1]; sVrAnticlipOffset[2] = m[2];
}

float sm64_vr_anticlip_world_scale(void) { return sVrScale; }

static float sVrEyeVP[2][4][4];
static float sVrHudVP[2][4][4];
static volatile int sVrValid = 0;      // read by the ENGINE thread
static int sVrWorld = 0;               // world mode on (vs the clear-only probe)

// ---------------------------------------------------------------------------
// EYE RESOLUTION (Austin, 2026-08-07: "quality is a little jagged — not as good
// as old 3D stereo mode"). Measured, and he was right about the cause:
//
//   3D panel : engine 3840x2160 onto a ~1400x790 footprint = 2.7x SUPERsampling
//   VR       : the same texture across a 5087x4081 per-eye view = 0.75x across,
//              0.53x DOWN — upsampling, and the engine has no MSAA, so every
//              jagged edge is magnified instead of averaged away.
//
// Foveation is not the problem: it is on and correct (device contract reads
// foveation=1, ratemaps=2, and each view's own map is attached). The problem is
// that the panel's pixel budget was never meant to cover a whole field of view.
//
// So VR sizes its own eye textures: the view's LOGICAL viewport (what the
// compositor rasterizes against, and ~1:1 with physical pixels at the centre
// where you are looking) times a render scale. Fixing the ASPECT alone is free —
// the old 16:9 texture wasted width and starved height on a 1.25 view.
static volatile int sVrViewW = 0, sVrViewH = 0;   // per-eye logical viewport
static float sVrRenderScale = 0.75f;              // donor ships a 0.4-1.0 slider

void sm64_vr_spike_set_render_scale(float s) {
    if (s >= 0.3f && s <= 1.3f) { sVrRenderScale = s; }
}

// The size gfx_metal allocates and gfx_pc renders at, in VR. Returns 0 when VR
// is not driving, so the panel path keeps its own sizing untouched.
int sm64_vr_spike_render_size(int *w, int *h) {
    int vw = sVrViewW, vh = sVrViewH;
    if (!sVrValid || vw < 64 || vh < 64) { return 0; }
    int rw, rh;
    if (sVrPanelMode) {
        // A SCREEN, not a view: 16:9, because that is the shape the game's menus
        // and HUD are laid out for. Rendering them into the view's boxy 1.25
        // aspect made the menu both squat and too tall for its own frame — the
        // clipped top Austin hit. Costs a texture reallocation when a menu opens,
        // which is a frame boundary and not gameplay.
        rw = (int)(vw * sVrRenderScale);
        rh = (int)(rw * 9.0f / 16.0f);
    } else {
        rw = (int)(vw * sVrRenderScale);
        rh = (int)(vh * sVrRenderScale);
    }
    rw = ((rw + 64) / 128) * 128;   // quantise so a slider DRAG cannot thrash
    rh = ((rh + 64) / 128) * 128;   // the texture allocation every pixel
    if (rw < 640) { rw = 640; }
    if (rh < 640) { rh = 640; }
    if (w) { *w = rw; }
    if (h) { *h = rh; }
    return 1;
}

// WORLD LOCK (Austin, 2026-08-07: "add a toggle to headlock or not"). This is
// the R0->R1 line: the PLACEMENT stays frozen in the room (that is what makes
// the diorama stay put), but the VIEW is rebuilt from the LIVE head pose every
// frame, so turning your head looks around the world instead of dragging it with
// you. Off = the frozen view R0 shipped with, which reads as head-locked.
static int sVrWorldLock = 1;

// Surroundings dimming, same control the flat 3D panel has. Replaces the "Full
// VR" button: Austin's note is that Full VR should mean first-person immersion,
// not "the room is hidden", and hiding the room is just this slider at 100%.
// Default 1.0 = no passthrough.
static float sVrDim = 1.0f;

void sm64_vr_spike_set_world_lock(int on) { sVrWorldLock = on ? 1 : 0; }

// PANEL MODE (charter A5). Set from the engine thread every frame; read by both
// the engine (through the accessors below, which go NULL so the game renders its
// own flat projection) and this loop (which then draws the frame on a quad
// instead of across your whole view). A one-frame disagreement at a menu
// boundary is harmless — the frame is either flat-on-a-panel or stereo, never a
// mixture, because both sides read the same flag.
void sm64_vr_spike_set_panel_mode(int on) { sVrPanelMode = on ? 1 : 0; }
int  sm64_vr_spike_panel_mode(void) { return sVrPanelMode; }

void sm64_vr_spike_set_dim(float dim) {
    dim = (dim < 0.0f) ? 0.0f : (dim > 1.0f ? 1.0f : dim);
    // Same perceptual curve as the panel's dimming: a LINEAR slider "doesn't
    // really get dark until 80%", measured on a human (sm64_immersive.m).
    sVrDim = 1.0f - powf(1.0f - dim, 2.2f);
}

void sm64_vr_spike_set_tunables(float scale, float dist, float height, float stereo) {
    if (scale  >= 100.0f && scale <= 20000.0f) { sVrScale  = scale;  }
    if (dist   >= -1.0f  && dist  <= 5.0f)     { sVrDist   = dist;   }
    if (height >= -3.0f  && height <= 3.0f)    { sVrHeight = height; }
    if (stereo >= 0.0f   && stereo <= 1.5f)    { sVrStereo = stereo; }
}

// Re-freeze the head pose on the next tracked frame. If "too close to my face"
// turns out to be a BAD CAPTURE (a pose read before tracking settled — the trap
// that once put the 3D panel on the floor) rather than a placement number, this
// button is what tells the two apart.
static volatile int sVrRefreeze = 0;
void sm64_vr_spike_recenter(void) { sVrRefreeze = 1; }


// The head-locked HUD plane (charter A6): how far ahead the 2D layer sits, and
// how wide it is there. 1.5 m is the charter's number; the half-width gives the
// game's 2D layer a ~50 degree span, which is close to how big it feels on the
// flat panel.
static const float kVrHudDist = 1.5f;
static const float kVrHudHalfW = 0.70f;
static const float kVrHudHalfH = 0.52f;  // 4:3 against the half-width

// Called from gfx_stereo_projection on the engine thread, once per matrix
// composition — kept to a flag test and a pointer.
const float *sm64_vr_eye_viewproj(int eye) {
    if (!sVrValid || sVrPanelMode || eye < 1 || eye > 2) { return NULL; }
    return &sVrEyeVP[eye - 1][0][0];
}

const float *sm64_vr_hud_matrix(int eye) {
    if (!sVrValid || sVrPanelMode || eye < 1 || eye > 2) { return NULL; }
    return &sVrHudVP[eye - 1][0][0];
}

int sm64_vr_hide_background(void) { return sVrWorld && !sVrPanelMode; }

// The compositor's own projection with ONLY its depth row replaced.
//
// WHY THE ENGINE CANNOT TAKE THE MATRIX UNCHANGED (R0 finding): the compositor
// supports REVERSE-Z only for the drawable's depth (drawable.h: "It only
// supports reverse-Z depth ... 1 for near 0 for far"), while the engine renders
// forward-Z (clear 1.0, less-equal) on every target it owns. A reverse-Z
// projection inverts its depth test and sorts the world back to front.
//
// WHY IT IS NO LONGER REBUILT FROM RECOVERED TANGENTS, which is the fix for
// Austin's 2026-08-07 device report ("0% IPD, the doubling is further apart;
// 100%, the two Mario doubles get slightly closer"). That reading is the
// signature of a per-eye CONSTANT angular offset: with each eye's rotation and
// frustum correctly paired, 0% separation must give two IDENTICAL images — flat,
// but fused — and only worse-than-that if the frustum does not match the
// rotation. Vision Pro's displays are CANTED, so each eye's frustum is strongly
// asymmetric to match; decomposing that matrix into tangents and rebuilding it
// puts one silent assumption (WHERE Apple stores the off-centre terms, and with
// which sign) between us and a correct frustum, and getting it wrong
// symmetrises the frusta. The donor paid for exactly this once, on the same
// class of hardware (vr.c:561-568): "Forcing it symmetric here pointed both
// eyes' frustum centers inward -> the images converge -> CROSS-EYED (double
// vision)". It is invisible on our simulator, which is mono and symmetric.
//
// So: keep Apple's matrix verbatim — x row, y row, w row, asymmetry, whatever
// convention it is in — and overwrite ONLY the z row. Nothing about the frustum
// can then be lost in translation, because it is never translated.
static simd_float4x4 sm64_vr_forward_z_projection(simd_float4x4 P, float zn, float zf) {
    // clip.w = wz * z. -1 is the -Z-forward convention we expect; read it rather
    // than assume it, because the whole point here is to stop assuming.
    float wz = P.columns[2].w;
    float A, B;
    if (wz < 0.0f) {          // w = -z: map z=-zn -> 0, z=-zf -> 1
        A = zf / (zn - zf);
        B = zn * zf / (zn - zf);
    } else {                  // w = +z: the mirrored convention
        A = zf / (zf - zn);
        B = -zn * zf / (zf - zn);
    }
    P.columns[0].z = 0.0f;
    P.columns[1].z = 0.0f;
    P.columns[2].z = A;
    P.columns[3].z = B;
    return P;
}

// ---------------------------------------------------------------------------
// EYE DUMP — the donor's instrument ("the one that settled the carpet argument
// on PC", QUEST_PORT_NOTES). Writes both ENGINE eye textures to Documents as
// PNGs, which `devicectl device copy from` can pull off the headset.
//
// It answers the one question reasoning cannot: do the two rendered images
// actually carry the ~36° cant the device's frusta ask for? If they do, the
// engine honoured the asymmetric projections and the fault is downstream; if
// they look like the same framing shifted slightly, the asymmetry is being lost
// inside the engine, and THAT is a permanent per-eye displacement no stereo
// setting can rescue — exactly what Austin is seeing.
static volatile int sVrDumpRequest = 0;
void sm64_vr_spike_dump_eyes(void) { sVrDumpRequest = 1; }

static void sm64_vr_write_png(id<MTLTexture> src, id<MTLCommandQueue> queue, NSString *name) {
    if (src == nil) { return; }
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                           width:src.width
                                                          height:src.height
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;   // readable by the CPU
    id<MTLTexture> host = [src.device newTextureWithDescriptor:td];
    if (host == nil) { return; }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(src.width, src.height, 1)
                toTexture:host destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    size_t w = host.width, h = host.height, stride = w * 4;
    void *bytes = malloc(stride * h);
    if (!bytes) { return; }
    [host getBytes:bytes bytesPerRow:stride fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    // The engine renders BGRA8Unorm; tell CoreGraphics so the dump is not
    // channel-swapped (a red Mario would be a distraction, not a finding).
    CGBitmapInfo bi = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    CGContextRef ctx = CGBitmapContextCreate(bytes, w, h, 8, stride, cs, bi);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (img) {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:name]];
        CGImageDestinationRef dst =
            CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (CFStringRef)@"public.png", 1, NULL);
        if (dst) {
            CGImageDestinationAddImage(dst, img, NULL);
            CGImageDestinationFinalize(dst);
            CFRelease(dst);
            NSLog(@"[vrspike] eye dump wrote %@ (%zux%zu)", name, w, h);
        }
        CGImageRelease(img);
    }
    if (ctx) { CGContextRelease(ctx); }
    CGColorSpaceRelease(cs);
    free(bytes);
}

// One-time dump of what the compositor actually handed us, per eye, so the
// asymmetry is a READ NUMBER and not an inference. tR+tL far from zero means a
// canted eye; equal-and-opposite tangents on both eyes would mean symmetric
// frusta, and would move the suspicion elsewhere.
static void sm64_vr_log_projection(int eye, simd_float4x4 cp, simd_float4x4 fixed) {
    float m00 = cp.columns[0].x, m11 = cp.columns[1].y;
    float ox = cp.columns[2].x, oy = cp.columns[2].y;
    float tR = (fabsf(m00) > 1e-6f) ? (ox + 1.0f) / m00 : 0.0f;
    float tL = (fabsf(m00) > 1e-6f) ? (ox - 1.0f) / m00 : 0.0f;
    float tU = (fabsf(m11) > 1e-6f) ? (oy + 1.0f) / m11 : 0.0f;
    float tD = (fabsf(m11) > 1e-6f) ? (oy - 1.0f) / m11 : 0.0f;
    NSLog(@"[vrspike] PROJ eye=%d cp: c0=(%.4f,%.4f,%.4f,%.4f) c1=(%.4f,%.4f,%.4f,%.4f) "
           "c2=(%.4f,%.4f,%.4f,%.4f) c3=(%.4f,%.4f,%.4f,%.4f)",
          eye,
          cp.columns[0].x, cp.columns[0].y, cp.columns[0].z, cp.columns[0].w,
          cp.columns[1].x, cp.columns[1].y, cp.columns[1].z, cp.columns[1].w,
          cp.columns[2].x, cp.columns[2].y, cp.columns[2].z, cp.columns[2].w,
          cp.columns[3].x, cp.columns[3].y, cp.columns[3].z, cp.columns[3].w);
    NSLog(@"[vrspike] PROJ eye=%d tangents R=%.4f L=%.4f U=%.4f D=%.4f | offCentre x=%.4f y=%.4f "
           "(0 = symmetric; Vision Pro's canted eyes should NOT be 0) | fixed c2.z=%.4f c3.z=%.4f",
          eye, tR, tL, tU, tD, tR + tL, tU + tD, fixed.columns[2].z, fixed.columns[3].z);
}

// Place the game's camera space in the room: camera origin sVrDist ahead of the
// frozen head at kVrHeight, facing the way the head faced (levelled — no pitch
// or roll leaks into the world, the same rule the 3D panel already follows).
static simd_float4x4 sm64_vr_placement(simd_float4x4 frozenHead, simd_float4x4 liveHead) {
    simd_float3 headPos = frozenHead.columns[3].xyz;
    simd_float3 fwd = -frozenHead.columns[2].xyz;
    fwd.y = 0.0f;
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

    simd_float3 pos = headPos + fwd * sVrDist;
    pos.y += sVrHeight;

    // The collision anti-clip's answer from the previous frame, in the anchor's
    // own axes (it was computed in game-camera space, which is what this frame
    // maps FROM).
    simd_float3 right = simd_normalize(simd_cross(simd_make_float3(0, 1, 0), -fwd));
    pos += right * sVrAnticlipOffset[0];
    pos.y += sVrAnticlipOffset[1];
    pos += fwd * (-sVrAnticlipOffset[2]);

    // ANTI-CLIP (charter R2, donor vr.c:288/519). Keep the anchor at least
    // kVrClipMargin from your ACTUAL head, and push it away along the line
    // between you when you get closer — so leaning in to look at the diorama
    // backs the world off instead of letting you put your face inside it. The
    // distance slider is therefore free to go negative (third-person parks the
    // game's camera essentially at you) without the world ending up in your
    // skull: this is what enforces the floor, not a clamp on the number.
    //
    // Eased rather than snapped: a hard correction reads as the world flinching.
    // This is the GEOMETRIC half of the donor's anti-clip; theirs also runs level
    // collision so the eye cannot end up inside a wall, which needs the engine
    // thread and is a later step.
    {
        simd_float3 livePos = liveHead.columns[3].xyz;
        simd_float3 toAnchor = pos - livePos;
        float d = simd_length(toAnchor);
        if (d < kVrClipMargin) {
            simd_float3 dir = (d > 1e-4f) ? (toAnchor / d) : fwd;
            float want = kVrClipMargin - d;
            sVrClipPush += (want - sVrClipPush) * 0.25f;   // ease in fast
            pos += dir * sVrClipPush;
        } else if (sVrClipPush > 0.0005f) {
            sVrClipPush *= 0.90f;                          // relax back slowly
            simd_float3 dir = (d > 1e-4f) ? (toAnchor / d) : fwd;
            pos += dir * sVrClipPush;
        } else {
            sVrClipPush = 0.0f;
        }
    }

    simd_float3 zAxis = -fwd;                                   // camera looks down -Z
    simd_float3 yAxis = simd_make_float3(0, 1, 0);
    simd_float3 xAxis = simd_normalize(simd_cross(yAxis, zAxis));
    yAxis = simd_cross(zAxis, xAxis);

    simd_float4x4 m;
    m.columns[0] = simd_make_float4(xAxis, 0.0f);
    m.columns[1] = simd_make_float4(yAxis, 0.0f);
    m.columns[2] = simd_make_float4(zAxis, 0.0f);
    m.columns[3] = simd_make_float4(pos, 1.0f);
    return m;
}

// Rebuilt EVERY frame (two 4x4 multiplies per eye — nothing) so the settings
// sliders move the world while you drag them. The POSE is still frozen: this is
// R0, and keeping the pose out of the loop means a world that looks wrong is a
// matrix or a number, never pose plumbing.
// Where the flat panel sits in panel mode: level, facing you, anchored to the
// same head pose the world is. Distance and size are fixed for now — the point
// of this screen is legibility, not another slider.
static const float kVrPanelDist  = 2.6f;
static const float kVrPanelHalfH = 0.95f;   // ~1.9 m tall at 2.6 m; the width follows
                                            // the (now 16:9) render, so ~3.4 m across
static const float kVrPanelDrop  = 0.20f;   // metres below eye level — dead level reads
                                            // as slightly too high to sit and look at

static simd_float4x4 sm64_vr_panel_placement(simd_float4x4 frozenHead) {
    simd_float3 headPos = frozenHead.columns[3].xyz;
    simd_float3 fwd = -frozenHead.columns[2].xyz;
    fwd.y = 0.0f;
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;
    simd_float3 pos = headPos + fwd * kVrPanelDist;
    pos.y -= kVrPanelDrop;

    simd_float3 zAxis = -fwd;
    simd_float3 yAxis = simd_make_float3(0, 1, 0);
    simd_float3 xAxis = simd_normalize(simd_cross(yAxis, zAxis));
    yAxis = simd_cross(zAxis, xAxis);

    simd_float4x4 m;
    m.columns[0] = simd_make_float4(xAxis, 0.0f);
    m.columns[1] = simd_make_float4(yAxis, 0.0f);
    m.columns[2] = simd_make_float4(zAxis, 0.0f);
    m.columns[3] = simd_make_float4(pos, 1.0f);
    return m;
}

static void sm64_vr_build_matrices(cp_drawable_t drawable, simd_float4x4 frozenHead,
                                   simd_float4x4 liveHead, bool logIt) {
    const float invS = 1.0f / sVrScale;
    simd_float4x4 scale = matrix_identity_float4x4;
    scale.columns[0].x = invS; scale.columns[1].y = invS; scale.columns[2].z = invS;
    simd_float4x4 place = sm64_vr_placement(frozenHead, liveHead);
    simd_float4x4 A = simd_mul(place, scale);

    // The cyclopean eye in GAME-CAMERA space, for the engine's collision pass:
    // invert the placement to get from the room back into the game's camera
    // frame, then out of metres into world units.
    {
        simd_float4 headLocal = simd_mul(simd_inverse(place),
                                         simd_make_float4(liveHead.columns[3].xyz, 1.0f));
        sVrHeadCamPos[0] = headLocal.x * sVrScale;
        sVrHeadCamPos[1] = headLocal.y * sVrScale;
        sVrHeadCamPos[2] = headLocal.z * sVrScale;
        sVrHeadCamValid = 1;
    }

    // Clip planes in METRES (A has already taken game units out). Near 0.05 is
    // the donor's decal z-fight lesson; far tracks the world's scaled size.
    const float zn = 0.05f;
    const float zf = 8000.0f * invS * 3.0f + 5.0f;

    size_t views = cp_drawable_get_view_count(drawable);

    // Publish the logical viewport so the eye textures can be sized from the
    // VIEW rather than from the flat panel's budget.
    {
        MTLViewport vp0 = cp_view_texture_map_get_viewport(
            cp_view_get_view_texture_map(cp_drawable_get_view(drawable, 0)));
        if (vp0.width > 64 && vp0.height > 64) {
            sVrViewW = (int)vp0.width;
            sVrViewH = (int)vp0.height;
        }
    }

    // Cyclopean centre of the eyes in DEVICE space, so the stereo scale shrinks
    // the offsets around the head centre exactly as the donor does
    // (vr.c:507-509) instead of around one eye — which would swing the whole
    // world sideways as the slider moves.
    simd_float3 centre = simd_make_float3(0, 0, 0);
    if (views >= 2) {
        simd_float3 e0 = cp_view_get_transform(cp_drawable_get_view(drawable, 0)).columns[3].xyz;
        simd_float3 e1 = cp_view_get_transform(cp_drawable_get_view(drawable, 1)).columns[3].xyz;
        centre = (e0 + e1) * 0.5f;
    }

    for (size_t v = 0; v < 2; v++) {
        size_t src = (v < views) ? v : 0;   // the SIMULATOR is mono: both eyes take view 0
        cp_view_t view = cp_drawable_get_view(drawable, src);
        simd_float4x4 deviceFromEye = cp_view_get_transform(view);
        // THE COMFORT LEVER (donor vr.c:507-509). Rotation untouched — only the
        // eye's offset from the head centre is scaled, so the frustum stays the
        // runtime's own and only the parallax softens.
        simd_float3 eyePos = deviceFromEye.columns[3].xyz;
        simd_float3 scaled = centre + (eyePos - centre) * sVrStereo;
        deviceFromEye.columns[3] = simd_make_float4(scaled, 1.0f);

        // The PLACEMENT (A, above) uses the frozen head — that is the anchor in
        // the room. The VIEW uses the LIVE head when world lock is on, which is
        // the whole difference between looking around a world and wearing it.
        simd_float4x4 viewHead = sVrWorldLock ? liveHead : frozenHead;
        simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(viewHead, deviceFromEye));
        simd_float4x4 cpProj = matrix_identity_float4x4;
        if (__builtin_available(visionOS 2.0, *)) {
            cpProj = cp_drawable_compute_projection(
                drawable, cp_axis_direction_convention_right_up_back, src);
        }
        simd_float4x4 P = sm64_vr_forward_z_projection(cpProj, zn, zf);
        simd_float4x4 M = simd_mul(P, simd_mul(eyeFromOrigin, A));
        memcpy(&sVrEyeVP[v][0][0], &M, sizeof(sVrEyeVP[v])); // simd column-major == fast3d transpose

        // The HUD plane (charter A6). Maps the game's own ortho OUTPUT — which is
        // already NDC — onto a quad kVrHudDist metres ahead in HEAD space, then
        // through this eye's frustum. Head space, not eye space, is the whole
        // point: a quad at a real distance from the head gives both eyes the
        // disparity that distance deserves, where the old pass-through gave the
        // 2D layer zero TEXTURE disparity and therefore a huge ANGULAR one.
        // The donor's ledger entry, avoided rather than re-earned: their VR panel
        // rendered at HALF the size of every other menu because it rode the
        // gameplay HUD quad. A menu over the world gets menu-sized.
        float hudW = sVrMenuOverWorld ? (kVrHudHalfW * 1.9f) : kVrHudHalfW;
        float hudH = sVrMenuOverWorld ? (kVrHudHalfH * 1.9f) : kVrHudHalfH;
        simd_float4x4 plane = (simd_float4x4){{ {0,0,0,0}, {0,0,0,0}, {0,0,0,0}, {0,0,0,0} }};
        plane.columns[0].x = hudW;          // ndc.x -> metres across the plane
        plane.columns[1].y = hudH;          // ndc.y -> metres up the plane
        plane.columns[3].z = -kVrHudDist;   // the plane's distance, ndc.z discarded
        plane.columns[3].w = 1.0f;
        simd_float4x4 eyeFromDevice = simd_inverse(deviceFromEye);
        simd_float4x4 hud = simd_mul(P, simd_mul(eyeFromDevice, plane));
        memcpy(&sVrHudVP[v][0][0], &hud, sizeof(sVrHudVP[v]));
        if (logIt) {
            sm64_vr_log_projection((int)v, cpProj, P);
            // The PUBLISHED matrix, all 16 values, in the row-vector form the
            // engine consumes. If the cant is present here but absent from the
            // rendered image, the asymmetry is being lost inside the engine.
            NSLog(@"[vrspike] EyeVP[%zu] fast3d rows: "
                   "[%.5f %.5f %.5f %.5f][%.5f %.5f %.5f %.5f]"
                   "[%.5f %.5f %.5f %.5f][%.5f %.5f %.5f %.5f]", v,
                  sVrEyeVP[v][0][0], sVrEyeVP[v][0][1], sVrEyeVP[v][0][2], sVrEyeVP[v][0][3],
                  sVrEyeVP[v][1][0], sVrEyeVP[v][1][1], sVrEyeVP[v][1][2], sVrEyeVP[v][1][3],
                  sVrEyeVP[v][2][0], sVrEyeVP[v][2][1], sVrEyeVP[v][2][2], sVrEyeVP[v][2][3],
                  sVrEyeVP[v][3][0], sVrEyeVP[v][3][1], sVrEyeVP[v][3][2], sVrEyeVP[v][3][3]);
        }
        if (logIt) {
            NSLog(@"[vrspike] EyeVP[%zu] view %zu: eye(%.4f,%.4f,%.4f) -> scaled(%.4f,%.4f,%.4f)",
                  v, src, (double)eyePos.x, (double)eyePos.y, (double)eyePos.z,
                  (double)scaled.x, (double)scaled.y, (double)scaled.z);
        }
    }
    if (logIt) {
        NSLog(@"[vrspike] matrices published (scale=%.0f u/m dist=%.2fm(min %.2f) height=%.2fm "
               "stereo=%.2f zn=%.3f zf=%.1f)",
              sVrScale, sVrDist, kVrClipMargin, sVrHeight, sVrStereo, zn, zf);
        sVrValid = 1;   // so the size query below answers (the matrices are written)
        int rw = 0, rh = 0;
        if (sm64_vr_spike_render_size(&rw, &rh)) {
            NSLog(@"[vrspike] eye render %dx%d for a %dx%d view -> sampling %.2fx/%.2fx "
                   "(scale %.2f; >1 supersamples, <1 upsamples and shows jaggies)",
                  rw, rh, sVrViewW, sVrViewH,
                  (double)rw / (double)sVrViewW, (double)rh / (double)sVrViewH, sVrRenderScale);
        }
    }
    sVrValid = 1;
}

// --- the fullscreen eye copy -------------------------------------------------
//
// "Full-slice blit" as a DRAW rather than a blit encoder: the engine texture and
// the drawable disagree on pixel format (and, on device, on size), which a blit
// encoder cannot bridge — and a draw can also write the drawable's depth in the
// same pass, which the compositor requires.
static NSString *const kSM64VRShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
     "vertex VOut vr_vs(uint vid [[vertex_id]], constant float& depth [[buffer(0)]]) {\n"
     "  const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
     "  VOut o; o.pos = float4(p[vid], depth, 1.0);\n"
     "  o.uv = float2((p[vid].x + 1.0) * 0.5, 1.0 - (p[vid].y + 1.0) * 0.5);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 vr_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                      constant float& srgbDecode [[buffer(0)]]) {\n"
     "  constexpr sampler s(filter::linear);\n"
     "  float4 c = tex.sample(s, in.uv);\n"
     // SPIKE KEYING, not a shipping technique: the engine clears its frame to
     // OPAQUE black, so without this the game's empty space would paper over the
     // whole view and there would be nothing for the world to hang IN. Dropping
     // near-black fragments (which also skips their depth write) previews the
     // diorama-over-passthrough look the donor's rung 2 gets properly, by
     // clearing to alpha 0 instead.
     "  if (all(c.rgb < 0.02)) { discard_fragment(); }\n"
     "  if (srgbDecode > 0.5) { c.rgb = pow(c.rgb, float3(2.2)); }\n"
     "  return float4(c.rgb, 1.0);\n"
     "}\n"
     // Surroundings dimming: a black layer at the given alpha, drawn UNDER the
     // world so the room fades out behind it. At 1.0 there is no passthrough
     // left, which is what "no passthrough" means without a second space.
     "vertex float4 vr_dim_vs(uint vid [[vertex_id]], constant float& depth [[buffer(0)]]) {\n"
     "  const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
     "  return float4(p[vid], depth, 1.0);\n"
     "}\n"
     "fragment float4 vr_dim_fs(constant float& dim [[buffer(0)]]) {\n"
     "  return float4(0.0, 0.0, 0.0, dim);\n"
     "}\n"
     // Panel mode: the flat frame on a world-locked quad, the same presentation
     // the shipped 3D mode uses. Opaque, and no black keying — a menu screen is
     // MEANT to be a screen.
     "vertex VOut vr_quad_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
     "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
     "  o.uv = float2(p[vid].x * 0.5 + 0.5, 0.5 - p[vid].y * 0.5);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 vr_quad_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                           constant float& srgbDecode [[buffer(0)]]) {\n"
     "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
     "  float4 c = tex.sample(s, in.uv);\n"
     "  if (srgbDecode > 0.5) { c.rgb = pow(c.rgb, float3(2.2)); }\n"
     "  return float4(c.rgb, 1.0);\n"
     "}\n";

static id<MTLRenderPipelineState> sVrPipeline;
static id<MTLRenderPipelineState> sVrDimPipeline;
static id<MTLRenderPipelineState> sVrQuadPipeline;
static id<MTLDepthStencilState> sVrDepthState;
// Mipmapped per-eye copies, latched as an atomic pair (see the copy site).
static id<MTLTexture> sVrEyeCopy[2];
static uint32_t sVrLastGen = 0;
// The anchor each pair was rendered from: pending = published this frame (the
// engine is rendering with it now), shown = the one the pair on screen came from.
static ar_device_anchor_t sVrPendingAnchor = nil;
static ar_device_anchor_t sVrShownAnchor = nil;

static void sm64_vr_build_pipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSM64VRShader options:nil error:&err];
    if (!lib) { NSLog(@"[vrspike] shader compile FAILED: %@", err.localizedDescription); return; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vr_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"vr_fs"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.depthAttachmentPixelFormat = depthFmt;
    sVrPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!sVrPipeline) { NSLog(@"[vrspike] pipeline FAILED: %@", err.localizedDescription); return; }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES; // the compositor reprojects on depth and rejects what it cannot read
    sVrDepthState = [dev newDepthStencilStateWithDescriptor:dd];

    MTLRenderPipelineDescriptor *dp = [MTLRenderPipelineDescriptor new];
    dp.vertexFunction = [lib newFunctionWithName:@"vr_dim_vs"];
    dp.fragmentFunction = [lib newFunctionWithName:@"vr_dim_fs"];
    dp.colorAttachments[0].pixelFormat = colorFmt;
    dp.colorAttachments[0].blendingEnabled = YES;
    dp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    dp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    dp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    dp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    dp.depthAttachmentPixelFormat = depthFmt;
    sVrDimPipeline = [dev newRenderPipelineStateWithDescriptor:dp error:&err];
    if (!sVrDimPipeline) { NSLog(@"[vrspike] dim pipeline FAILED: %@", err.localizedDescription); }

    MTLRenderPipelineDescriptor *qp = [MTLRenderPipelineDescriptor new];
    qp.vertexFunction = [lib newFunctionWithName:@"vr_quad_vs"];
    qp.fragmentFunction = [lib newFunctionWithName:@"vr_quad_fs"];
    qp.colorAttachments[0].pixelFormat = colorFmt;
    qp.depthAttachmentPixelFormat = depthFmt;
    sVrQuadPipeline = [dev newRenderPipelineStateWithDescriptor:qp error:&err];
    if (!sVrQuadPipeline) { NSLog(@"[vrspike] quad pipeline FAILED: %@", err.localizedDescription); }
    NSLog(@"[vrspike] world pipeline built (colorFmt=%lu depthFmt=%lu)",
          (unsigned long)colorFmt, (unsigned long)depthFmt);
}

// --- contract dump -----------------------------------------------------------
//
// Everything the drawable exposes about its shape, rendered into ONE string so a
// change between styles is a string comparison rather than an eyeball diff of
// scattered log lines. Logged on the first frame and on every change thereafter
// — a live .mixed -> .full switch that alters the contract therefore announces
// itself on the frame it happens.
static NSString *sm64_vr_contract_string(cp_layer_renderer_t lr, cp_drawable_t drawable) {
    cp_layer_renderer_configuration_t cfg = cp_layer_renderer_get_configuration(lr);
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"layout=%u foveation=%d colorFmt=%lu depthFmt=%lu",
        (unsigned)cp_layer_renderer_configuration_get_layout(cfg),
        (int)cp_layer_renderer_configuration_get_foveation_enabled(cfg),
        (unsigned long)cp_layer_renderer_configuration_get_color_format(cfg),
        (unsigned long)cp_layer_renderer_configuration_get_depth_format(cfg)];

    size_t views = cp_drawable_get_view_count(drawable);
    size_t texcount = cp_drawable_get_texture_count(drawable);
    size_t rmcount = cp_drawable_get_rasterization_rate_map_count(drawable);
    simd_float2 dr = cp_drawable_get_depth_range(drawable);
    [s appendFormat:@" | views=%zu textures=%zu ratemaps=%zu depthRange=[%.4f,%.4f] target=%d",
        views, texcount, rmcount, (double)dr.x, (double)dr.y,
        (int)cp_drawable_get_target(drawable)];

    for (size_t t = 0; t < texcount; t++) {
        id<MTLTexture> c = cp_drawable_get_color_texture(drawable, t);
        id<MTLTexture> d = cp_drawable_get_depth_texture(drawable, t);
        [s appendFormat:@" | tex%zu color=%lux%lu arr=%lu type=%lu fmt=%lu depth=%@",
            t, (unsigned long)c.width, (unsigned long)c.height,
            (unsigned long)c.arrayLength, (unsigned long)c.textureType,
            (unsigned long)c.pixelFormat,
            d ? [NSString stringWithFormat:@"%lux%lu arr=%lu fmt=%lu",
                    (unsigned long)d.width, (unsigned long)d.height,
                    (unsigned long)d.arrayLength, (unsigned long)d.pixelFormat]
              : @"nil"];
    }
    for (size_t v = 0; v < views; v++) {
        cp_view_t vw = cp_drawable_get_view(drawable, v);
        cp_view_texture_map_t tm = cp_view_get_view_texture_map(vw);
        MTLViewport vp = cp_view_texture_map_get_viewport(tm);
        simd_float4x4 xf = cp_view_get_transform(vw);
        [s appendFormat:@" | view%zu texIdx=%zu slice=%zu vp=(%.0f,%.0f %.0fx%.0f) eyePos=(%.4f,%.4f,%.4f)",
            v, cp_view_texture_map_get_texture_index(tm),
            cp_view_texture_map_get_slice_index(tm),
            vp.originX, vp.originY, vp.width, vp.height,
            (double)xf.columns[3].x, (double)xf.columns[3].y, (double)xf.columns[3].z];
    }
    return s;
}

// The A3 verification the charter calls non-negotiable, run here on the SPIKE's
// own terms: the two views' eye transforms must differ by roughly an IPD along
// eye-space X. Logged once. If this is not ~0.06 m the composition convention is
// wrong and no amount of sign-flipping downstream will fix it.
static void sm64_vr_log_ipd(cp_drawable_t drawable) {
    if (cp_drawable_get_view_count(drawable) < 2) {
        NSLog(@"[vrspike] IPD CHECK: only %zu view(s) — the SIMULATOR is mono, so this "
               "check is device-only", cp_drawable_get_view_count(drawable));
        return;
    }
    simd_float4x4 a = cp_view_get_transform(cp_drawable_get_view(drawable, 0));
    simd_float4x4 b = cp_view_get_transform(cp_drawable_get_view(drawable, 1));
    simd_float3 d = b.columns[3].xyz - a.columns[3].xyz;
    NSLog(@"[vrspike] IPD CHECK: eye1-eye0 = (%.4f, %.4f, %.4f) m  |len|=%.4f m "
           "(expect ~0.063 along X)", (double)d.x, (double)d.y, (double)d.z,
          (double)simd_length(d));
}

void sm64_vr_spike_run(void *layer_renderer_ptr, int variant) {
    cp_layer_renderer_t layer_renderer = (__bridge cp_layer_renderer_t)layer_renderer_ptr;
    sm64_vr_spike_stop = 0;
    sm64_vr_spike_running = 1;

    NSLog(@"[vrspike] loop started (variant=%d)", variant);

    id<MTLCommandQueue> queue = nil;
    NSString *lastContract = nil;
    int frames = 0;
    int styleStage = 0; // variant 2's live-switch state machine

    // R0.2: world mode, ON unless explicitly disabled. Default-on because the
    // DEVICE has no env channel — the headset run is the one that matters, and
    // it must show the world. SM64_VR_WORLD=0 gets R0.1's clear-only style probe
    // back on the simulator.
    {
        const char *w = getenv("SM64_VR_WORLD");
        sVrWorld = (w && *w == '0') ? 0 : 1;
    }
    sVrValid = 0;
    sVrEyeCopy[0] = sVrEyeCopy[1] = nil;
    sVrPendingAnchor = sVrShownAnchor = nil;
    sVrLastGen = sm64_metal_get_3d_pair_gen(); // wait for a pair rendered THIS session
    bool frozenSet = false;
    simd_float4x4 frozenHead = matrix_identity_float4x4;
    NSLog(@"[vrspike] world mode = %d", sVrWorld);

    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);

    int running = 1;
    while (running) {
        if (sm64_vr_spike_stop) {
            NSLog(@"[vrspike] stop requested, exiting (frames=%d)", frames);
            running = 0;
            continue;
        }
        switch (cp_layer_renderer_get_state(layer_renderer)) {
            case cp_layer_renderer_state_paused:
                cp_layer_renderer_wait_until_running(layer_renderer);
                continue;
            case cp_layer_renderer_state_invalidated:
                NSLog(@"[vrspike] layer INVALIDATED, exiting (frames=%d)", frames);
                running = 0;
                continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        @autoreleasepool {
            cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
            if (frame == NULL) { continue; }

            cp_frame_timing_t timing = cp_frame_predict_timing(frame);
            cp_frame_start_update(frame);
            cp_frame_end_update(frame);
            cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
            cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
            if (drawable == NULL) {
                cp_frame_end_submission(frame);
                continue;
            }

            if (queue == nil) {
                id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
                queue = [t0.device newCommandQueue];
                sm64_vr_log_ipd(drawable);
                if (sVrWorld) {
                    sm64_vr_build_pipeline(t0.device, t0.pixelFormat,
                                           cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
                }
            }

            // Contract dump: first frame and every change. The whole spike.
            NSString *contract = sm64_vr_contract_string(layer_renderer, drawable);
            if (lastContract == nil || ![contract isEqualToString:lastContract]) {
                NSLog(@"[vrspike] CONTRACT (variant=%d frame=%d): %@", variant, frames, contract);
                lastContract = contract;
            }

            CFTimeInterval presTime = cp_time_to_cf_time_interval(
                cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
            ar_device_anchor_t anchor = ar_device_anchor_create();
            ar_device_anchor_query_status_t anchorStatus =
                ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
            // (submitted below, once we know which pair this frame shows)

            // R0.2: freeze the pose ONCE tracking has converged (ARKit's first
            // frames answer success with a near-identity pose — the same trap
            // that put the 3D panel on the floor), then compose EyeVP and hand
            // it to the engine. Frozen, so nothing after this depends on pose
            // plumbing.
            simd_float4x4 liveHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
            if (sVrWorld && (!frozenSet || sVrRefreeze) && frames > 30 &&
                anchorStatus == ar_device_anchor_query_status_success) {
                sVrRefreeze = 0;
                frozenHead = liveHead;
                frozenSet = true;
                NSLog(@"[vrspike] world ANCHORED at head (%.2f,%.2f,%.2f) worldLock=%d",
                      (double)frozenHead.columns[3].x, (double)frozenHead.columns[3].y,
                      (double)frozenHead.columns[3].z, sVrWorldLock);
                sm64_vr_build_matrices(drawable, frozenHead, liveHead, true);
            } else if (sVrWorld && frozenSet) {
                // Every frame: the world's PLACEMENT stays anchored where it was
                // put, the VIEW follows the live head (when world lock is on), and
                // the tunables are live so dragging a slider moves the world while
                // you look at it — the donor's "tuned by feel" workflow.
                sm64_vr_build_matrices(drawable, frozenHead, liveHead, false);
            }

            // THE POSE WE RENDER WITH MUST BE THE POSE WE SUBMIT (donor ledger:
            // "world shakes with head sway"). The engine renders its pair AFTER
            // this frame's signal, so the pair we are about to SHOW was built
            // from the anchor we published on a PREVIOUS frame — submit that one,
            // and let the compositor reproject the difference. Submitting the
            // live anchor for a frame rendered from an older pose is exactly the
            // mismatch that reads as the world swimming with your head.
            if (anchorStatus == ar_device_anchor_query_status_success) {
                sVrPendingAnchor = anchor;
            }
            // Release the engine's next paced frame only NOW, after this frame's
            // matrices are published, so it renders with them and not with the
            // previous frame's pose. Without any signal at all the engine falls
            // back to its 50 ms timeout — ~20 Hz into a 90 Hz compositor.
            sm64_3d_pace_signal_now();

            id<MTLCommandBuffer> cb = [queue commandBuffer];

            // ATOMIC EYE PAIR (the trap this tree already paid for once — 3D
            // batch 3 item 1b). The engine renders L then R sequentially, so
            // sampling "whatever is latest" per eye can pair L from frame N with
            // R from frame N-1: a per-eye TIME skew, which reads as doubling on
            // everything that moves. Copy both eyes only when the pair
            // generation has advanced, and otherwise re-show the pair we already
            // have — the two eyes are then always the same instant.
            if (sVrWorld) {
                uint32_t gen = sm64_metal_get_3d_pair_gen();
                if (gen != sVrLastGen) {
                    sVrLastGen = gen;
                    // This pair was rendered from the matrices published on the
                    // frame whose anchor is still pending — that is the pose to
                    // present it against.
                    sVrShownAnchor = sVrPendingAnchor;
                    for (int e = 0; e < 2; e++) {
                        id<MTLTexture> src =
                            (__bridge id<MTLTexture>)sm64_metal_get_3d_eye_texture(e + 1);
                        if (src == nil || src.device != queue.device) { continue; }
                        if (sVrEyeCopy[e] == nil || sVrEyeCopy[e].width != src.width ||
                            sVrEyeCopy[e].height != src.height ||
                            sVrEyeCopy[e].pixelFormat != src.pixelFormat) {
                            MTLTextureDescriptor *td = [MTLTextureDescriptor
                                texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                             width:src.width
                                                            height:src.height
                                                         mipmapped:YES];
                            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                            td.storageMode = MTLStorageModePrivate;
                            sVrEyeCopy[e] = [src.device newTextureWithDescriptor:td];
                        }
                        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                        [blit copyFromTexture:src toTexture:sVrEyeCopy[e]];
                        if (sVrEyeCopy[e].mipmapLevelCount > 1) {
                            [blit generateMipmapsForTexture:sVrEyeCopy[e]];
                        }
                        [blit endEncoding];
                    }
                }
            }

            // Eye dump: once automatically after the world has settled, and on
            // demand from the settings button. Done here, where this loop owns a
            // Metal queue and the copies are a known-complete pair.
            if (sVrWorld && (sVrDumpRequest || frames == 300) && sVrEyeCopy[0] && sVrEyeCopy[1]) {
                sVrDumpRequest = 0;
                sm64_vr_write_png(sVrEyeCopy[0], queue, @"vr-eye-L.png");
                sm64_vr_write_png(sVrEyeCopy[1], queue, @"vr-eye-R.png");
            }

            cp_drawable_set_device_anchor(drawable,
                (sVrWorld && sVrShownAnchor != nil) ? sVrShownAnchor : anchor);

            size_t views = cp_drawable_get_view_count(drawable);
            for (size_t v = 0; v < views; v++) {
                cp_view_t vw = cp_drawable_get_view(drawable, v);
                cp_view_texture_map_t tm = cp_view_get_view_texture_map(vw);
                size_t texIdx = cp_view_texture_map_get_texture_index(tm);
                size_t slice = cp_view_texture_map_get_slice_index(tm);
                MTLViewport vp = cp_view_texture_map_get_viewport(tm);

                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
                pass.colorAttachments[0].slice = slice;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                // PARTIAL ALPHA on purpose: in .mixed the room must show through
                // this wash; in .full it must not. Distinct hue per eye so a
                // mono/duplicated presentation is visible rather than assumed.
                pass.colorAttachments[0].clearColor = sVrWorld
                    ? MTLClearColorMake(0.0, 0.0, 0.0, 0.0)       // world: passthrough behind it
                    : ((v == 0) ? MTLClearColorMake(0.10, 0.35, 0.90, 0.50)   // left: blue
                                : MTLClearColorMake(0.90, 0.30, 0.10, 0.50)); // right: orange
                size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
                if (rmCount > 0) {
                    pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(
                        drawable, texIdx < rmCount ? texIdx : 0);
                }
                id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIdx);
                if (depthTex) {
                    pass.depthAttachment.texture = depthTex;
                    pass.depthAttachment.slice = slice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = 1.0;
                }
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
                [enc setViewport:vp];

                // Surroundings dimming, UNDER the world (the world's near-black
                // fragments are discarded, so whatever is behind them shows —
                // the room at 0, black at 1).
                if (sVrWorld && sVrDim > 0.003f && sVrDimPipeline) {
                    float dimDepth = 0.0001f;   // reverse-Z: ~far, behind everything
                    float dimNow = sVrDim;
                    [enc setRenderPipelineState:sVrDimPipeline];
                    [enc setDepthStencilState:sVrDepthState];
                    [enc setVertexBytes:&dimDepth length:sizeof(dimDepth) atIndex:0];
                    [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }

                // PANEL MODE (charter A5): the flat frame on a world-locked
                // quad, anchored where the world was. The projection here is
                // Apple's OWN (reverse-Z, untouched) because this quad is drawn
                // by us in the compositor's pass — only the engine needs the
                // forward-Z rebuild.
                if (sVrWorld && sVrPanelMode && sVrQuadPipeline && sVrEyeCopy[0]) {
                    id<MTLTexture> src = sVrEyeCopy[(v < 2) ? v : 0];
                    if (src == nil) { src = sVrEyeCopy[0]; }
                    simd_float4x4 cpProj = matrix_identity_float4x4;
                    if (__builtin_available(visionOS 2.0, *)) {
                        cpProj = cp_drawable_compute_projection(
                            drawable, cp_axis_direction_convention_right_up_back, v);
                    }
                    // The panel is PLACED from the anchored head (so it stays
                    // put in the room) but VIEWED from the LIVE one — using the
                    // frozen head for both is what glued it to your face, so you
                    // could never look up at the top of a menu. Same rule the
                    // world follows.
                    simd_float4x4 deviceFromEye = cp_view_get_transform(vw);
                    simd_float4x4 panelViewHead = sVrWorldLock ? liveHead : frozenHead;
                    simd_float4x4 eyeFromOrigin =
                        simd_inverse(simd_mul(panelViewHead, deviceFromEye));

                    // Sized from the TEXTURE's aspect, so the flat frame fills
                    // the quad exactly — the engine renders at the VR view's
                    // shape, and letterboxing it here would just waste panel.
                    float texAspect = (src.height > 0)
                        ? (float)src.width / (float)src.height : (16.0f / 9.0f);
                    float halfH = kVrPanelHalfH, halfW = kVrPanelHalfH * texAspect;

                    simd_float4x4 place = sm64_vr_panel_placement(frozenHead);
                    simd_float4x4 scaleM = matrix_identity_float4x4;
                    scaleM.columns[0].x = halfW;
                    scaleM.columns[1].y = halfH;
                    simd_float4x4 mvp = simd_mul(cpProj,
                        simd_mul(eyeFromOrigin, simd_mul(place, scaleM)));

                    float srgbDecode =
                        (src.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                         src.pixelFormat == MTLPixelFormatRGBA8Unorm) ? 1.0f : 0.0f;
                    [enc setRenderPipelineState:sVrQuadPipeline];
                    [enc setDepthStencilState:sVrDepthState];
                    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                    [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                    [enc setFragmentTexture:src atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
                // GAMEPLAY: paint this eye's engine render over the whole slice.
                else if (sVrWorld && sVrValid && sVrPipeline) {
                    id<MTLTexture> src = sVrEyeCopy[(v < 2) ? v : 0];
                    if (src == nil) { src = sVrEyeCopy[0] ? sVrEyeCopy[0] : sVrEyeCopy[1]; }
                    if (src != nil) {
                        // Reverse-Z depth for the whole image at the diorama's
                        // distance. The compositor takes ONLY reverse-Z here
                        // (1 = near), which is exactly why the engine's own
                        // projection had to stay forward-Z: the two conventions
                        // meet at this line and nowhere else.
                        simd_float2 dr = cp_drawable_get_depth_range(drawable);
                        float znDrawable = (dr.y > 0.0001f) ? dr.y : 0.1f;
                        float depth = znDrawable / (sVrDist + 1.0f);
                        if (depth > 1.0f) { depth = 1.0f; }
                        float srgbDecode =
                            (src.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                             src.pixelFormat == MTLPixelFormatRGBA8Unorm) ? 1.0f : 0.0f;
                        [enc setRenderPipelineState:sVrPipeline];
                        [enc setDepthStencilState:sVrDepthState];
                        [enc setVertexBytes:&depth length:sizeof(depth) atIndex:0];
                        [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                        [enc setFragmentTexture:src atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    }
                }
                [enc endEncoding];
            }

            cp_drawable_encode_present(drawable, cb);
            [cb commit];
            cp_frame_end_submission(frame);

            frames++;
            if (frames == 1 || frames == 10 || (frames % 300) == 0) {
                NSLog(@"[vrspike] variant=%d frame=%d PRESENTED (survived encode_present)",
                      variant, frames);
            }

            // Variant 2, clear-only probe: drive a LIVE style switch off this
            // loop's own frame clock. ~90 Hz on device, ~60 on the sim, so the
            // stages are a few seconds apart either way. If a switch changes the
            // contract, the dump above prints it; if it aborts, the log simply
            // stops here. In WORLD mode the ornament's Passthrough/Full button
            // drives the same switch by hand instead — an automatic flip every
            // few seconds is unreadable when there is a world to look at.
            if (variant == 2 && !sVrWorld) {
                if (styleStage == 0 && frames >= 240) {
                    styleStage = 1;
                    NSLog(@"[vrspike] LIVE SWITCH -> .full (frame %d)", frames);
                    SM64_SetVRSpikeStyleFull(true);
                } else if (styleStage == 1 && frames >= 540) {
                    styleStage = 2;
                    NSLog(@"[vrspike] LIVE SWITCH -> .mixed (frame %d)", frames);
                    SM64_SetVRSpikeStyleFull(false);
                } else if (styleStage == 2 && frames >= 840) {
                    styleStage = 3;
                    NSLog(@"[vrspike] LIVE SWITCH -> .full again (frame %d)", frames);
                    SM64_SetVRSpikeStyleFull(true);
                }
            }
        } // @autoreleasepool
    }

    // Hand the projection back to the panel path BEFORE the thread dies, or the
    // engine keeps composing a VR matrix into a frame nobody is showing in VR.
    sVrValid = 0;
    sVrPipeline = nil;
    sVrDepthState = nil;
    sVrEyeCopy[0] = sVrEyeCopy[1] = nil;
    NSLog(@"[vrspike] loop finished (variant=%d frames=%d)", variant, frames);
    sm64_vr_spike_running = 0;
}

#endif // SM64_VISION_3D
