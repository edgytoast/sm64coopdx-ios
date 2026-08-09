#ifndef CONTROLLER_VISION_H
#define CONTROLLER_VISION_H

// PSVR2 Sense controllers as an N64 pad (charter R3 / A10). Registered beside
// controller_sdl in controller_entry_point.c; self-gating, so it does not exist
// on iOS or desktop.

#include "pc/vision3d/sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#include "pc/controller/controller_api.h"

extern struct ControllerAPI controller_vision;

// One line of controller inventory for the VR panel: how many pads, each one's
// product category, and how many buttons/dpads it exposes. Readable in-headset
// because that is where the person who can generate it actually is.
void sm64_vr_pad_status(char *buf, int len);

#endif // SM64_VISION_3D
#endif // CONTROLLER_VISION_H
