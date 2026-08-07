#ifndef SM64_VR_SPIKE_H
#define SM64_VR_SPIKE_H

// R0 SPIKE — THROWAWAY. Not part of the shipping VR mode.
//
// VR-CHARTER §5 R0.1: prove the immersion-style contract for a SECOND immersive
// space before anything is built on it. The recorded trap (SM64VisionApp.swift
// :243-247) is that merely ALLOWING .progressive in the EXISTING space's style
// set changed the drawable contract and aborted cp_drawable_encode_present
// (__BUG_IN_CLIENT__). A7's preferred path — one "SM64-VR" space with
// .immersionStyle(selection:, in: .mixed, .full) switching live — is the same
// SHAPE as that trap, so it must be measured, not assumed.
//
// Three spaces are declared instead of one switchable one, deliberately: the
// question is what each style SET does to the contract, and a set is fixed at
// scene-declaration time. Opening them one at a time answers all three, and the
// middle one additionally answers "does a LIVE switch survive".
//
//   variant 1  "SM64-VR-MIXED"   .immersionStyle(.constant(.mixed), in: .mixed)
//   variant 2  "SM64-VR-SWITCH"  .immersionStyle($style,  in: .mixed, .full)
//                                 + a live .mixed -> .full -> .mixed switch
//   variant 3  "SM64-VR-FULL"    .immersionStyle(.constant(.full),  in: .full)
//
// The loop itself is the minimum that can present: clear each view to a colour
// with PARTIAL alpha (so passthrough showing through is visible in .mixed and
// its absence is visible in .full), write depth, present. Every contract fact
// the drawable exposes is logged on the first frame and on every CHANGE, which
// is what makes "did the style switch change the contract" a readable answer
// rather than an inference.

#include "sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#ifdef __cplusplus
extern "C" {
#endif

// The spike render loop, run on its own thread from the CompositorLayer closure
// (same rule as the 3D loop: never the main thread). variant is 1/2/3 above.
void sm64_vr_spike_run(void *layer_renderer, int variant);

// Loop handshake, same contract as sm64_3d_imm_stop/running.
extern volatile int sm64_vr_spike_stop;
extern volatile int sm64_vr_spike_running;

// Enter/exit. variant 0 = exit. Implemented in sm64_vision_host.m, which owns
// the transition sequencing: the engine goes offscreen BEFORE the space opens,
// because in .full the 2D window is certainly hidden and a hidden window's
// nextDrawable never returns.
void sm64_vr_spike_enter(int variant);

// Which variant is live (0 = none). Written by sm64_vr_spike_enter.
extern volatile int sm64_vr_spike_variant;

// Live style switch for variant 2, driven from the loop's own frame clock.
// Implemented in Swift (@_cdecl); declared here so the loop can call it.
void SM64_SetVRSpikeStyleFull(bool full);

// Live tunables, pushed by sm64_3d_apply_settings from the settings sheet while
// the sliders are dragged. scale = game units per metre, dist/height in metres,
// stereo = eye offset as a fraction of the true IPD (the donor's cross-eye
// lever, 0.50 shipped). Out-of-range values are ignored per-field.
void sm64_vr_spike_set_tunables(float scale, float dist, float height, float stereo);

// Re-freeze the head pose on the next tracked frame ("Recenter VR World").
void sm64_vr_spike_recenter(void);

#ifdef __cplusplus
}
#endif

#endif // SM64_VISION_3D
#endif // SM64_VR_SPIKE_H
