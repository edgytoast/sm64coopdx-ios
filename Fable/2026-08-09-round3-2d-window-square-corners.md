# ROUND 3 — the 2D window loses its rounded corners half a second after launch

Small, isolated, and long-running: this is the last known defect before the
public 1.2.0 release. Austin has asked for a deep dive rather than another
guess from me, and I have a concrete mechanism to put in front of you — but the
timeline does not fully fit it, which is exactly where I want a second opinion.

## Symptom

The ordinary flat visionOS window (before entering 3D or VR):

- shows **correct rounded corners for roughly half a second** at launch,
- then becomes **fully square** and stays that way for the session.

Austin reports the public 1.1.2 release does not do this. That has NOT been
re-verified on the current OS (your round-1 advice — bisect the OTA ladder —
is still the cheapest check and is still outstanding).

## The mechanism I believe is responsible

SDL2 2.32.10 has **no scene support at all**: it creates its own `UIWindow` and
calls `makeKeyAndVisible` without ever assigning `.windowScene`. Under the
scene lifecycle (which `UIApplicationSceneManifest` forces, and which
`openImmersiveSpace` requires) a scene-less window is never shown at all — so
`sm64_vision_host.m` adopts it:

```objc
// SM64_AdoptSDLWindowIntoScene()
win.windowScene = (UIWindowScene *)s;   // s = the foreground-active UIWindowScene
```

That makes the SDL window a **SECONDARY window inside the SwiftUI
WindowGroup's scene**. The SwiftUI window is the primary one and carries the
system's glass/corner treatment.

Then, every frame, from the game loop's main-thread hook:

```objc
// SM64_TrackSDLWindowToScene()
CGRect b = scene.coordinateSpace.bounds;
if (!CGRectEqualToRect(win.frame, b)) { win.frame = b; }
```

So an opaque `CAMetalLayer`-backed secondary window is stretched to the **full
scene bounds** — including the corners the system rounds off on the primary
window. Nothing in our code sets `cornerRadius`, `mask`, or `masksToBounds` on
that window or its layer (grepped; there is no such call anywhere in the tree).

**The timing fits exactly.** At launch the SwiftUI window is up and correctly
rounded. Within a beat, the engine finishes booting, the game loop starts
calling `sm64_3d_frame_poll()`, `SM64_TrackSDLWindowToScene()` runs for the
first time, the SDL window is sized to the full bounds, and its square opaque
content covers the rounded chrome. Half a second is about how long the engine
takes to reach its loop.

**Why I am not simply fixing it:** the resize glue was added 2026-07-16, well
BEFORE the VR phase (which began 2026-08-07), so on this theory the corners
should have been square in 1.1.1 and 1.1.2 as well. Either Austin's memory of
the older builds is off, or something in the VR phase changed this window's
behaviour indirectly, or visionOS 26.x changed the chrome under us. I cannot
tell which, and I have already made things worse twice by acting on a
plausible-but-unverified mechanism.

## Questions

1. **Is the mechanism above right?** Specifically: on visionOS, does a
   *secondary* `UIWindow` adopted into a scene get the system's rounded-corner
   treatment at all, or is that treatment applied only to the scene's primary
   (SwiftUI-owned) window?
2. **What is the correct fix?** Candidates, best first, but I would rather have
   your ruling than pick:
   - Apply the system corner radius to the SDL window's layer
     (`cornerRadius` + `masksToBounds`, possibly `cornerCurve = .continuous`).
     If so, **where does the correct radius come from** — is there an API for
     it, or is hardcoding the only option (and what happens when the user
     resizes, since the radius may not be constant)?
   - Host the SDL view *inside* the SwiftUI view hierarchy instead of adopting
     a second window at all. Much larger change, and it fights SDL2's window
     ownership, but it removes the whole class of problem.
   - Inset `win.frame` slightly from the scene bounds. Cheap, but it trades
     square corners for visible margins — probably wrong.
3. **Is `win.frame = scene.coordinateSpace.bounds` even the right target?**
   That glue exists because UIKit does not relayout an adopted secondary window
   when the user resizes the visionOS window, so without it the drawable stays
   frozen at its 1920x1080 creation size (black margins when expanding, cropped
   when shrinking). If there is a scene-correct way to get that relayout, it
   likely fixes the corners for free.
4. **Does any of this interact with the window becoming unmovable?** Austin hit
   a session where the 2D window could not be dragged by gaze-pinch with either
   hands or controller; **a Vision Pro reboot cleared it** and it has not
   recurred. That smells like system-level window state rather than our code,
   but it is the second odd window-level symptom on this app and I would rather
   mention it than sit on it.

## Facts already established (please do not re-tread)

- No `cornerRadius` / `clipsToBounds` / `maskedCorners` / `isOpaque` handling
  anywhere in our sources.
- `git diff` of `app/gfx/gfx_metal.mm` since the 1.1.1 release: **no** changes
  to layer properties, drawable size, or frame/bounds handling.
- `git diff` of `app/vision3d/sm64_vision_host.m` and `SM64VisionApp.swift`
  since 1.1.1: no window or scene changes that apply at launch. The window
  *parking* code (`sm64_3d_park_window`, `UIWindowSceneGeometryPreferencesVision`)
  runs only on entering 3D/VR, long after the corners have already squared.
- The SDL compat patch (`overlay/assets/sdl2-visionos-compat.patch`) does touch
  `SDL_uikitwindow.m`, `SDL_uikitviewcontroller.m`, `SDL_uikitvideo.m` and
  `SDL_uikitmetalview.m` — but all of that predates the VR phase and shipped in
  1.1.1.

## Code

- `app/vision3d/sm64_vision_host.m:126-170` — `SM64_AdoptSDLWindowIntoScene()`
  and `SM64_TrackSDLWindowToScene()`. The whole hypothesis lives in these two
  functions.
- `app/vision3d/SM64VisionApp.swift` — the SwiftUI `WindowGroup` (primary
  window) and the three immersive spaces.
- `overlay/assets/sdl2-visionos-compat.patch` — SDL's own window/metalview glue.

## Everything else is done

For context on priority: hands, the sky dome, the spatial controllers and
first-person are all working on device as of 1.1.2.32. This is the last known
defect before cutting the public 1.2.0, so a definitive answer here unblocks
the release — but it is also cosmetic, and if the honest ruling is "ship it and
file feedback with Apple", that is a perfectly good outcome.
