#ifndef DJUI_PANEL_VR_H
#define DJUI_PANEL_VR_H

// The in-game VR options panel (Options -> VR), modelled on the donor's
// djui_panel_vr.c. Pulled forward from the charter's R2 at Austin's request
// (2026-08-07): inside the headset the flat window's settings sheet is not
// somewhere you want to reach, and every one of these controls describes the
// thing you are currently looking at.
//
// THE DIVISION OF LABOUR, so a setting never has two homes:
//   this panel        — the VR presentation you are inside (world placement,
//                       stereo, sharpness, dimming, world lock, recenter)
//   the visionOS sheet — the flat 3D PANEL's own settings (screen size,
//                       distance, focus), which you tune while looking at it
// Both read and write ONE store (sm64_3d_setting_f / _set_f), so they cannot
// disagree; this panel is a second view onto the same values, not a second copy.
//
// Plain C on purpose: DJUI is engine code compiled for every platform, so this
// file must not touch UIKit. It self-gates on SM64_VISION_3D, which is how it
// stays absent from iOS and desktop builds entirely.

#include "pc/vision3d/sm64_vision_3d.h"

#ifdef SM64_VISION_3D

struct DjuiBase;
void djui_panel_vr_create(struct DjuiBase *caller);

#endif // SM64_VISION_3D
#endif // DJUI_PANEL_VR_H
