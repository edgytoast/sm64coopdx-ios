// SM64VisionApp.swift — SwiftUI app entry for the visionOS target.
//
// visionOS requires a SwiftUI `App` to declare an `ImmersiveSpace` (UIKit cannot
// open one), so the app entry is SwiftUI — but it only HOSTS the existing
// UIKit/SDL engine (SM64HostViewController boots it) in a WindowGroup, and
// declares the ImmersiveSpace for stereoscopic 3D. All engine/shell logic stays
// in C/ObjC; this file is scene plumbing only.
//
// NOTE ON THE FILENAME: this file must NOT be called main.swift. Swift treats a
// file with that exact name as top-level code, which collides with @main
// ("'main' attribute cannot be used in a module that contains top-level code").
// Measured, not guessed — it is the first thing that failed in the build spike.

import SwiftUI
import CompositorServices
import AVFAudio

// Shared bridge the ObjC/C side pokes to open/close the 3D immersive space.
final class SM64AppModel: ObservableObject {
    static let shared = SM64AppModel()
    @Published var immersive = false
    @Published var showSettings = false
    // R0 SPIKE (throwaway): which VR spike space is open — 0 none, 1 mixed-only,
    // 2 mixed+full switchable, 3 full-only. See sm64_vr_spike.h.
    @Published var vrSpike: Int = 0
    // R0 SPIKE: the live style for variant 2's switchable space.
    @Published var vrSpikeFull: Bool = false
}

// R0 SPIKE ids, indexed by variant so the C side only ever passes an int.
private let sm64VRSpikeIDs = ["", "SM64-VR-MIXED", "SM64-VR-SWITCH", "SM64-VR-FULL"]

@_cdecl("SM64_SetVRSpikeMode")
func SM64_SetVRSpikeMode(_ variant: Int32) {
    DispatchQueue.main.async { SM64AppModel.shared.vrSpike = Int(variant) }
}

@_cdecl("SM64_SetVRSpikeStyleFull")
func SM64_SetVRSpikeStyleFull(_ full: Bool) {
    DispatchQueue.main.async {
        SM64AppModel.shared.vrSpikeFull = full
        NSLog("[vrspike] Swift: style -> \(full ? ".full" : ".mixed") (published)")
    }
}

// Called from sm64_vision_host.m to flip the SwiftUI state that actually
// opens/dismisses the space.
@_cdecl("SM64_SetImmersiveMode")
func SM64_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { SM64AppModel.shared.immersive = on }
}

// Settings "Done" bridge (the UIKit bar button cannot dismiss a SwiftUI sheet).
@_cdecl("SM64_CloseSettingsSheet")
func SM64_CloseSettingsSheet() {
    DispatchQueue.main.async { SM64AppModel.shared.showSettings = false }
}

@_cdecl("SM64_OpenSettingsSheet")
func SM64_OpenSettingsSheet() {
    DispatchQueue.main.async { SM64AppModel.shared.showSettings = true }
}

// In 3D, anchor the app's sound stage to the FRONT of the user — at the panel —
// instead of at the (parked-aside) 2D window (guide §2.7). Restored on exit.
//
// Comfort batch 2 item 4: the user reported the audio "sounds like it's to the
// right of me" — the sound stage following the parked window instead of the
// panel. The fix is anchoringStrategy: .front (below), which pins the stage to
// the user's front regardless of where the window sits. This ALSO logs the active
// AVAudioSession category so the applied state can be confirmed live over the
// port-8791 bridge (`logtail`) while the user plays — because whether it "worked"
// is an ears-on-device judgement, and the log is how we cross-check that the
// .front call actually fired and did not throw.
private func sm64SetAudioFrontStage(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        if on {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .medium, anchoringStrategy: .front))
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[sm64vp] Swift: audio spatial experience -> \(on ? "FRONT-anchored (medium stage)" : "automatic") "
            + "[session category=\(session.category.rawValue) active-route=\(session.currentRoute.outputs.first?.portType.rawValue ?? "none")]")
    } catch {
        NSLog("[sm64vp] Swift: setIntendedSpatialExperience(\(on ? "front" : "auto")) FAILED: \(error)")
    }
}

// Hosts the UIKit engine bootstrap inside SwiftUI.
struct SM64WindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SM64HostViewController {
        return SM64HostViewController()
    }
    func updateUIViewController(_ vc: SM64HostViewController, context: Context) {}
}

// Hosts the UIKit settings table in the SwiftUI sheet: a UIKit modal presented
// directly works in 2D but silently fails over an open ImmersiveSpace.
struct SM64SettingsSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        return SM64_MakeSettingsNav()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

// CompositorServices layer configuration for the immersive (3D) render path.
// Capabilities are QUERIED so we never request an unsupported combination —
// that makes openImmersiveSpace fail with a generic .error that names nothing.
struct SM64CompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        // FOVEATED RENDERING — the de-blur fix (VISIONOS-FOVEATION-GUIDE; origin
        // Ship of Harkinian D-036, device-validated 2026-07-22).
        //
        // Our engine's image is sharp; the softness the 3D panel had vs the 2D
        // window was lost in the COMPOSITOR HOP. A 2D window is composited by the
        // SYSTEM at panel density with dynamic eye-tracked foveation; our immersive
        // panel instead renders through our OWN CompositorServices drawable — a
        // fixed, uniformly-dense allocation the system then resamples to the panel.
        // Enabling foveation makes THAT drawable eye-tracked variable-density,
        // concentrating resolution exactly where the user looks: the effective
        // foveal resolution multiplies and the blur is gone. The engine (Metal
        // offscreen render) is untouched — only this panel-composite pass changes.
        // Cost is NEGATIVE (fewer total fragments than uniform density); SoH saw no
        // regression at 90-120 Hz. Ships UNCONDITIONAL: a toggle is just a way to
        // accidentally get the blur back.
        let fov = capabilities.supportsFoveation
        configuration.isFoveationEnabled = fov
        // TRAP (cost SoH a device round): .layered layout carries ONE multi-layer
        // rate map, but our per-slice render passes each rasterize with layer 0's
        // (left eye's) map — the compositor then unwarps the right eye with its own,
        // giving a right-eye fisheye that zooms with head motion. .dedicated gives
        // each eye its OWN texture AND its OWN rate map, which the per-view
        // texture-map targeting in sm64_immersive.m consumes correctly.
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
        // Do NOT touch maxRenderQuality (visionOS 26 API): requesting a raised
        // value ABORTS the process at immersive entry, on sim AND device, with no
        // non-aborting validation call. Foveation alone delivers the win.
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        NSLog("[sm64vp] Swift: compositor configured (layered=\(layouts.contains(.layered)) foveation=\(fov))")
    }
}

// The window's root View — owns the immersive open/close environment actions
// (only valid inside a View, NOT the App struct, where they silently no-op) and
// the ornament controls.
struct SM64RootView: View {
    @ObservedObject private var model = SM64AppModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        SM64WindowView()
            .ignoresSafeArea()
            // 3D + settings in a BOTTOM ornament, pushed fully BELOW the window.
            // contentAlignment .top anchors the pill's TOP edge to the window's
            // bottom edge — the default centered ornament straddles the boundary
            // and overlaps game content. .padding(.top) adds the clear gap.
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    if model.vrSpike == 0 {
                        Button(model.immersive ? "Exit" : "3D") {
                            sm64_3d_enter(!model.immersive)
                        }
                    }
                    // R0 SPIKE (throwaway): the device has no env channel, so the
                    // spike needs a control surface. "VR" opens the switchable
                    // (.mixed + .full) space with the frozen-pose world; while it
                    // is open the second button flips the style LIVE, which is the
                    // A7 question a headset has to answer by eye.
                    if !model.immersive {
                        Button(model.vrSpike == 0 ? "VR" : "Exit VR") {
                            sm64_vr_spike_enter(model.vrSpike == 0 ? 2 : 0)
                        }
                    }
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3) // larger, readable
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)
            }
            // WIDE sheet: precision room for the live panel sliders. The header
            // (with Done) is SwiftUI-owned — a hosted UIKit nav-bar Done does not
            // survive presentation from the small parked window, which would
            // leave the window-close X as the only exit (and that kills the audio
            // session). Width-only frame: forcing a height taller than the sheet
            // surface makes SwiftUI center-clip the content and eat the Done bar.
            .sheet(isPresented: $model.showSettings) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Settings").font(.title3.weight(.semibold))
                        Spacer()
                        // Reset moved here (2026-07-23) from the UIKit table header
                        // to sit just left of Done. Drives the live settings table
                        // via the SM64_ResetVision3D bridge (resets + reloads the
                        // visible sliders).
                        Button("Reset") { SM64_ResetVision3D() }
                            .font(.title3)
                            .buttonStyle(.bordered)
                        Button("Done") { model.showSettings = false }
                            .font(.title3)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    Divider()
                    SM64SettingsSheet()
                }
                .frame(minWidth: 900)
            }
            // R0 SPIKE (throwaway): open/dismiss whichever spike space the C side
            // asked for. Deliberately a SEPARATE onChange from the 3D one — the
            // whole point is that the two spaces' configurations stay independent
            // (the recorded trap is a style set changing the OTHER space's
            // drawable contract).
            .onChange(of: model.vrSpike) { old, v in
                NSLog("[vrspike] Swift: vrSpike onChange \(old) -> \(v)")
                Task {
                    if old != 0 {
                        await dismissImmersiveSpace()
                        NSLog("[vrspike] Swift: dismissed spike space")
                    }
                    if v > 0 && v < sm64VRSpikeIDs.count {
                        let id = sm64VRSpikeIDs[v]
                        let r = await openImmersiveSpace(id: id)
                        NSLog("[vrspike] Swift: openImmersiveSpace(\(id)) -> \(String(describing: r))")
                        if case .error = r {
                            sm64_vr_spike_enter(0) // roll the engine back out of offscreen mode
                        } else {
                            // Austin, 2026-08-07: "the SOUND follows where the black
                            // playing-in-VR little window is ... move the window to my
                            // left and the audio comes from my left." The 3D path has
                            // always anchored the stage to the user's FRONT; the spike
                            // never did, so the stage stayed on the parked 2D window.
                            sm64SetAudioFrontStage(true)
                            sm64_3d_park_window()
                        }
                    } else {
                        sm64SetAudioFrontStage(false)
                        sm64_3d_exit_finalize()
                    }
                }
            }
            .onChange(of: model.immersive) { _, on in
                NSLog("[sm64vp] Swift: immersive onChange -> \(on)")
                Task {
                    if on {
                        let r = await openImmersiveSpace(id: "SM64-3D")
                        NSLog("[sm64vp] Swift: openImmersiveSpace -> \(String(describing: r))")
                        if case .error = r {
                            // Roll everything back — the engine must not stay in
                            // offscreen mode with the window still visible, or it
                            // renders to textures nobody is showing.
                            sm64_3d_enter(false)
                        } else {
                            sm64SetAudioFrontStage(true)
                            // The space has finished opening — NOW park the 2D
                            // window down to a small card (guide §2.7). Doing it
                            // here rather than in sm64_3d_enter avoids a window
                            // resize animation colliding with the entry animation
                            // (vkQuake VKQHostViewController.m:63).
                            sm64_3d_park_window()
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("[sm64vp] Swift: dismissed immersive")
                        sm64SetAudioFrontStage(false)
                        sm64_3d_exit_finalize()
                    }
                }
            }
    }
}

// R0 SPIKE: spawn the spike loop on its own thread, same rule as the 3D loop.
private func sm64SpawnVRSpike(_ layerRenderer: LayerRenderer, _ variant: Int32) {
    NSLog("[vrspike] Swift: CompositorLayer ready (variant=\(variant)) — spawning render thread")
    let t = Thread {
        sm64_vr_spike_run(Unmanaged.passUnretained(layerRenderer).toOpaque(), variant)
    }
    t.name = "SM64-VR-Spike"
    t.stackSize = 2 << 20
    t.start()
}

@main
struct SM64VisionApp: App {
    // R0 SPIKE: the App observes the model so variant 2's style binding is live.
    @StateObject private var model = SM64AppModel.shared

    var body: some Scene {
        WindowGroup {
            SM64RootView()
        }
        ImmersiveSpace(id: "SM64-3D") {
            CompositorLayer(configuration: SM64CompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread; the frame loop must NOT
                // (it would block the engine's frame pump -> whole-app freeze).
                NSLog("[sm64vp] Swift: CompositorLayer ready — spawning render thread")
                let renderThread = Thread {
                    sm64_3d_immersive_run(Unmanaged.passUnretained(layerRenderer).toOpaque())
                }
                renderThread.name = "SM64-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // MIXED ONLY. Merely ALLOWING .progressive here changes the drawable
        // contract (portal rendering) and cp_drawable_encode_present aborts
        // __BUG_IN_CLIENT__. Crown-dimming would need real portal support; the
        // "Surroundings Dimming" slider is our in-app replacement.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // -------------------------------------------------------------------
        // R0 SPIKE (throwaway — VR-CHARTER §5 R0.1 / A7). Three separate spaces,
        // one per style SET, because a set is fixed at scene-declaration time.
        // Opening them one at a time answers "which survive encode_present" and
        // "does the drawable contract differ between styles"; variant 2 also
        // answers "does a LIVE switch survive".
        //
        // The existing SM64-3D space above is NOT touched — that independence is
        // exactly what A7 path (a) needs to be true.
        // -------------------------------------------------------------------
        ImmersiveSpace(id: "SM64-VR-MIXED") {
            CompositorLayer(configuration: SM64CompositorConfiguration()) { lr in
                sm64SpawnVRSpike(lr, 1)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        // YOUR arms, hidden — so the only hands in the world are Mario's.
        // upperLimbVisibility is the precise tool for this: passthrough stays
        // (the room, the furniture, the controllers you are holding are still
        // there), but the system stops compositing your limbs over the render.
        // Dimming the surroundings instead would have hidden the whole room to
        // solve a problem that is only about two hands.
        .upperLimbVisibility(.hidden)

        ImmersiveSpace(id: "SM64-VR-SWITCH") {
            CompositorLayer(configuration: SM64CompositorConfiguration()) { lr in
                sm64SpawnVRSpike(lr, 2)
            }
        }
        // The shape of the recorded trap: a style SET with more than one member,
        // switched live. A computed Binding rather than @State so the loop can
        // drive it from C through the published flag.
        .upperLimbVisibility(.hidden)
        .immersionStyle(selection: Binding<ImmersionStyle>(
            get: {
                NSLog("[vrspike] Swift: immersionStyle READ -> \(model.vrSpikeFull ? ".full" : ".mixed")")
                return model.vrSpikeFull ? .full : .mixed
            },
            set: { _ in }), in: .mixed, .full)

        ImmersiveSpace(id: "SM64-VR-FULL") {
            CompositorLayer(configuration: SM64CompositorConfiguration()) { lr in
                sm64SpawnVRSpike(lr, 3)
            }
        }
        .upperLimbVisibility(.hidden)
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
