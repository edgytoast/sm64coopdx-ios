#ifndef CONTROLLER_VISION_H
#define CONTROLLER_VISION_H

// PSVR2 Sense controllers as an N64 pad (charter R3 / A10). Registered beside
// controller_sdl in controller_entry_point.c; self-gating, so it does not exist
// on iOS or desktop.

#include "pc/vision3d/sm64_vision_3d.h"

#ifdef SM64_VISION_3D

#include "pc/controller/controller_api.h"

extern struct ControllerAPI controller_vision;

#endif // SM64_VISION_3D
#endif // CONTROLLER_VISION_H
