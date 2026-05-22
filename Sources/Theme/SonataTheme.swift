import SwiftUI

// MARK: - Theme
//
// Sonata's visual language, extracted from the startup loader (StartupGate.swift)
// so the rest of the app can pick up the same warm/dark/literary identity
// without redefining values inline.
//
// Scope (v0): semantic color tokens + typography roles. We are *not* repainting
// chrome — the system surface stays neutral. Warmth shows up on accents:
// primary buttons, focus rings, status text, section dividers.
//
// Naming is functional (e.g. `accentEmber`, `statusReady`) rather than mood-
// based. Functional names survive palette tweaks; mood names rot the first
// time the palette shifts.
//
// One file, two enums: `Theme.Color` and `Theme.Type`. Both are nested under
// `Theme` so call sites read `Theme.Color.accentEmber` / `Theme.Type.displayLarge`.
// Inside `Theme.Color`, members named `Color` would collide with SwiftUI's
// `Color`; fully qualify the SwiftUI type as `SwiftUI.Color` inside the enum.

enum Theme {

    // MARK: - Color tokens
    //
    // Source-of-truth values came from StartupGate.swift's hardcoded RGBs.
    // When the loader changes its palette, this is the only place that needs
    // to move — other views pull the named token.

    enum Color {

        // MARK: Background (loader gradient)
        //
        // Used together as a top→bottom gradient on the loader's deep stage.
        // Outside the loader they exist as tokens for any view that wants to
        // hint "we're on the ember surface" (e.g. a hero card, a modal that
        // owns its background). Don't paint the whole app these — they're
        // intentionally dark.

        /// Loader background, deepest stop. Top-of-gradient on the loader.
        static let bgEmberDeep   = SwiftUI.Color(red: 0.06, green: 0.03, blue: 0.02)
        /// Loader background, mid stop. ~55% down the loader gradient.
        static let bgEmberMid    = SwiftUI.Color(red: 0.12, green: 0.05, blue: 0.02)
        /// Loader background, top-of-glow stop. Bottom of the loader gradient.
        static let bgEmberTop    = SwiftUI.Color(red: 0.20, green: 0.08, blue: 0.03)

        /// Subtle warm tint usable behind cards / section dividers on otherwise
        /// neutral views. NOT a full repaint — apply at low opacity (≤0.06) to
        /// keep system surfaces feeling system-native. Currently sourced from
        /// `bgEmberTop` so we have a single warm-shell token to lean on.
        static let bgWarmShell   = SwiftUI.Color(red: 0.20, green: 0.08, blue: 0.03)

        // MARK: Chrome — warm dark shell (theme v1)
        //
        // Three opaque tones for the structural UI that surrounds content:
        // the window background, the nav rail, and any custom toolbar surface.
        // Stepped so they read as a layered palette rather than one flat dark:
        //
        //   bgDeep  (window)   — deepest, ~loader bottom
        //   bgMid   (nav rail) — one notch up, gives the rail separation
        //   bgWarmShell        — warmer top, reuse for hero/toolbar accents
        //
        // These are opaque on purpose: they replace the system window/sidebar
        // surfaces rather than tinting them. Content panes (lists, cards,
        // forms) should still use system surfaces so body text stays legible.

        /// Window background — the deepest warm dark. Sits behind everything
        /// when no other surface paints over it. Same RGB as `bgEmberDeep`;
        /// the alias exists so chrome call sites read as chrome ("window bg")
        /// rather than as loader gradient stops.
        static let bgDeep        = SwiftUI.Color(red: 0.06, green: 0.03, blue: 0.02)

        /// Nav rail / sidebar background. One step lighter than `bgDeep` so
        /// the rail separates from the window without needing a hard divider.
        /// Same RGB as `bgEmberMid`.
        static let bgMid         = SwiftUI.Color(red: 0.12, green: 0.05, blue: 0.02)

        // MARK: Chrome dividers & selection

        /// Warm divider replacing the cool `.separator` system color. Cream-ish
        /// hairline at low alpha — visible against `bgDeep`/`bgMid` without
        /// fighting the warm shell. Apply directly as a foreground/fill;
        /// already alpha'd, no `.opacity()` needed at call sites.
        static let dividerWarm   = SwiftUI.Color(red: 1.0, green: 0.80, blue: 0.55).opacity(0.22)

        /// Low-alpha ember overlay for selected rows in nav/lists. Replaces
        /// the system `accentColor.opacity(0.15)` recipe so selection reads
        /// warm against the new chrome surfaces. Already alpha'd.
        static let selectionTint = SwiftUI.Color(red: 1.0, green: 0.55, blue: 0.20).opacity(0.15)

        /// Full-ember tint for the selected row's icon + label. Same hue as
        /// `accentEmber`; the alias exists so selection sites read "selection
        /// color" and don't drift to a different accent if the brand color
        /// later splits.
        static let selectionAccent = SwiftUI.Color(red: 1.0, green: 0.55, blue: 0.20)

        // MARK: Accents — the wordmark gradient & primary actions

        /// Cream highlight — top of the wordmark gradient. Use sparingly: title
        /// highlights, hover/focus on warm chips. Cream against dark feels warm;
        /// against light system chrome it disappears, so don't put this on light
        /// backgrounds.
        static let accentCream   = SwiftUI.Color(red: 1.0,  green: 0.92, blue: 0.70)

        /// The signature ember orange — middle stop of the wordmark gradient,
        /// also the "ready" status color and the Skip button's stroke. This is
        /// the *primary* accent for buttons, focus rings, and active-state tints
        /// throughout the app. When in doubt, pick this.
        static let accentEmber   = SwiftUI.Color(red: 1.0,  green: 0.55, blue: 0.20)

        /// Deeper rust at the bottom of the wordmark gradient. Used as the
        /// wordmark-gradient floor and as a stop in the loader progress bar.
        /// In broader UI: gradient stops, hover-state depth, danger-adjacent
        /// warmth that isn't quite "error."
        static let accentRust    = SwiftUI.Color(red: 0.95, green: 0.40, blue: 0.12)

        /// Wordmark mid-orange — between cream and rust. Mostly internal to
        /// the loader's gradient; available if another gradient wants the same
        /// in-between stop.
        static let accentOrange  = SwiftUI.Color(red: 1.0,  green: 0.72, blue: 0.30)

        // MARK: Status tokens (paired with `CheckStatus` in the loader)
        //
        // Outside the loader, these read as a small status semaphore for any
        // process indicator: settings save flashes, sync states, plugin health
        // pills. Match the meaning, not the literal loader use:
        //
        //   - statusReady   = "done, succeeded" (warm ember)
        //   - statusRunning = "in progress, fine" (yellow-amber)
        //   - statusPending = "waiting, not yet" (faded amber)
        //   - statusFailed  = "broke" (red, the only non-warm token by design)

        /// "Succeeded / ready / saved" — same hue as `accentEmber`, intentionally
        /// equal so a "Saved!" flash visually rhymes with the primary action that
        /// triggered it.
        static let statusReady   = SwiftUI.Color(red: 1.0,  green: 0.55, blue: 0.20)

        /// "In progress / active / healthy" — warm yellow-amber. Lighter than
        /// `accentEmber` so a running indicator next to a ready one reads as
        /// "still cooking, not yet done."
        static let statusRunning = SwiftUI.Color(red: 1.0,  green: 0.82, blue: 0.55)

        /// "Pending / queued / not started" — faded amber. The loader uses this
        /// at 0.35 opacity for unstarted checks; apply `.opacity(0.35)` at the
        /// call site to match the loader feel.
        static let statusPending = SwiftUI.Color(red: 0.95, green: 0.78, blue: 0.55)

        /// "Failed / error" — the one non-warm token. Used for hard failures in
        /// loader checks and for inline form-validation errors. Don't reach for
        /// SwiftUI's `.red` when this token exists; the warmer red blends with
        /// the rest of the palette.
        static let statusFailed  = SwiftUI.Color(red: 0.95, green: 0.30, blue: 0.20)

        // MARK: Text-on-ember

        /// Body/status text color when sitting on top of an ember background
        /// (e.g. the loader's "Starting up…" line). Apply at ~0.75 opacity to
        /// match the loader. Don't use on light backgrounds — too low contrast.
        static let textOnEmber   = SwiftUI.Color(red: 0.95, green: 0.78, blue: 0.55)
    }

    // MARK: - Typography roles
    //
    // Apple's built-in "New York" is the default `.serif` design family on
    // macOS — polished, free, no font file to ship. We use serif for display
    // (titles, headers) where it sets tone; system sans for body where it
    // reads best at small sizes; monospaced for technical detail (IDs, status,
    // hashes, log lines).
    //
    // Sizes are tuned to macOS conventions — body at 13pt, captions at 11pt,
    // headings stepped up from there. Tune by eye if the surrounding chrome
    // calls for it; don't redefine sizes inline.
    //
    // Enum is `Typography` rather than `Type` because `Theme.Type` is Swift's
    // metatype syntax and would parse ambiguously at call sites.

    enum Typography {

        /// Page titles, hero headers. Serif italic, light weight, large.
        /// Reads as "this is the wordmark family but smaller." Use once per
        /// view max.
        static var displayLarge: Font {
            .system(size: 28, weight: .light, design: .serif).italic()
        }

        /// Section headers ("General", "Secrets", "Email Inboxes"…). Serif,
        /// regular weight, medium-size. Sits between body and `displayLarge`.
        /// Use on every section title in form-heavy views.
        static var displayMedium: Font {
            .system(size: 20, weight: .regular, design: .serif)
        }

        /// Modal / sheet titles. Serif, semibold so it holds up at smaller
        /// sizes in a contained surface.
        static var displaySmall: Font {
            .system(size: 16, weight: .semibold, design: .serif)
        }

        /// Default body text. System sans (San Francisco). NOT serif — serif
        /// at 13pt is harder to read on macOS than the system face. Body type
        /// is also NOT colored amber; readability beats vibe at this size.
        static var body: Font {
            .system(size: 13, weight: .regular)
        }

        /// Body, emphasized. Same size, semibold. Use for labeled inline values
        /// ("Owner Email", "Default nickname"…).
        static var bodyEmphasized: Font {
            .system(size: 13, weight: .semibold)
        }

        /// Technical detail — IDs, hashes, status indicators, code, log lines.
        /// Monospaced, slightly smaller than body so it visually recedes.
        static var detail: Font {
            .system(size: 12, weight: .regular, design: .monospaced)
        }

        /// Helper / caption text below a label. System sans, smaller.
        static var caption: Font {
            .system(size: 11, weight: .regular)
        }
    }
}

// MARK: - Chrome modifiers
//
// Inner sidebars (NavigationSplitView's sidebar column) and the macOS window
// titlebar both need warming. SwiftUI's built-in modifiers don't reach the
// titlebar — that area is owned by AppKit's NSWindow — so we use a small
// NSViewRepresentable to configure the window once after mount.

import AppKit
import SwiftTerm

extension LocalProcessTerminalView {
    /// Apply Sonata's warm chrome background to an embedded SwiftTerm view.
    /// Replaces the default cold black so the worker / supervisor / inspector /
    /// interactive consoles match the rest of the app's chrome.
    func applyWarmChrome() {
        nativeBackgroundColor = NSColor(Theme.Color.bgDeep)
    }

    /// Apply a warm, readable color treatment to a session terminal: a cream
    /// foreground (the app's text-on-ember tone) plus a vibrant, warm-leaning
    /// 16-color ANSI palette, while the background stays the warm chrome from
    /// `applyWarmChrome()`. Replaces the muted-gray default text with something
    /// legible and gives colored output (ls, git, …) a lively look over Sonata's
    /// ember surface.
    func applyWarmTerminalColors() {
        func c(_ hex: UInt32) -> SwiftTerm.Color {
            let r = UInt16((hex >> 16) & 0xff)
            let g = UInt16((hex >> 8) & 0xff)
            let b = UInt16(hex & 0xff)
            // Scale 0–255 → 0–65535 (×257 maps 0xff to 0xffff exactly).
            return SwiftTerm.Color(red: r &* 257, green: g &* 257, blue: b &* 257)
        }
        // Default (un-colored) text → the user's chosen terminal text color
        // (Settings → General). Defaults to Classic White; many pick Phosphor
        // Green. Read from UserDefaults so this works outside a SwiftUI View.
        nativeForegroundColor = TerminalTextColorSetting.currentNSColor
        installColors([
            c(0x33271e), c(0xe5534b), c(0x8fbf52), c(0xd9a441),  // 0-3:  black, red, green, yellow
            c(0x4a9fe0), c(0xd061a8), c(0x43b5a0), c(0xede4d1),  // 4-7:  blue, magenta, cyan, white
            c(0x6b5544), c(0xf26d63), c(0xa6d35f), c(0xecc25a),  // 8-11: br black, red, green, yellow
            c(0x6bb6ee), c(0xe07cc0), c(0x5fccb8), c(0xfdf6e3),  // 12-15: br blue, magenta, cyan, white
        ])
    }
}

// MARK: - Window opacity setting
//
// Single source of truth for the whole-window translucency setting. Both the
// App (which applies it to NSWindow.alphaValue) and SettingsView (the slider)
// reference these so the key and default can never drift apart.
enum WindowOpacitySetting {
    static let key = "sonata.windowOpacity"
    static let defaultValue: Double = 0.93
}

// MARK: - Terminal text color setting
//
// The default (un-colored) foreground for *session* terminals (Sona + Terminal
// kinds; Workers are intentionally left on the neutral default). Persisted as a
// "#RRGGBB" hex string in UserDefaults so it's readable both from SwiftUI
// (@AppStorage in SettingsView) and from `applyWarmTerminalColors()`, which runs
// outside any View.
enum TerminalTextColorSetting {
    static let key = "sonata.terminalTextColorHex"

    /// Soft Gray — the default. Matches SwiftTerm's own default foreground
    /// (#8A8A8A), a muted neutral that's easier on the eyes than pure white.
    /// (Phosphor Green is the popular pick; Classic White stays an option.)
    static let defaultHex = "#8A8A8A"

    struct Preset { let name: String; let hex: String }

    /// Preset swatches shown in Settings, in display order.
    static let presets: [Preset] = [
        Preset(name: "Soft Gray",      hex: "#8A8A8A"),
        Preset(name: "Classic White",  hex: "#FFFFFF"),
        Preset(name: "Phosphor Green", hex: "#3CFF3C"),
        Preset(name: "Amber",          hex: "#FFB000"),
        Preset(name: "Ember",          hex: "#FF8C33"),
        Preset(name: "Cream",          hex: "#EFE3C8"),
    ]

    static var currentHex: String {
        UserDefaults.standard.string(forKey: key) ?? defaultHex
    }

    static var currentNSColor: NSColor {
        NSColor(hexString: currentHex) ?? .white
    }
}

extension Notification.Name {
    /// Posted when the terminal text color setting changes, so every themed
    /// terminal (sessions + supervisor) can re-apply it live.
    static let sonataTerminalColorsChanged = Notification.Name("sonata.terminalColorsChanged")
}

extension NSColor {
    /// Parse a "#RRGGBB" / "RRGGBB" hex string into an sRGB color.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
            green: CGFloat((v >> 8) & 0xff) / 255.0,
            blue: CGFloat(v & 0xff) / 255.0,
            alpha: 1
        )
    }

    /// "#RRGGBB" for this color, converted to sRGB. nil if it can't be mapped.
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension View {
    /// Apply the warm-dark chrome treatment to a NavigationSplitView's sidebar
    /// content. Hides the system scroll background (which is a cool gray),
    /// fills with the `bgMid` chrome token the nav rail uses, and overlays a
    /// subtle film-grain noise so the inner sidebar feels like a different
    /// surface than the nav rail without needing a color difference.
    ///
    /// Why texture instead of color: a tonal-shift sidebar (tried `bgEmberTop`)
    /// reads as muddy reddish brown that fights the loader's amber. Static
    /// noise gives the surface "fabric" without changing its color.
    ///
    /// Apply directly inside the `sidebar:` closure of NavigationSplitView:
    ///
    ///   NavigationSplitView { mySidebarList.warmSidebar() } detail: { ... }
    ///
    /// `flame: true` swaps the subtle texture for the ember gradient +
    /// HouseFire shader + legibility wash (the Sessions / Workers look). The
    /// bottom-bright ember gradient is part of the flame treatment — it reads
    /// as the flame's light spilling onto the surface, so it's deliberately
    /// *not* applied when there's no flame (a bottom-lit gradient with no light
    /// source looks unmotivated; the flame-off branch keeps its top-lit
    /// texture instead). Opt-in (default off) because on long lists — Tasks,
    /// Wiki, People — the flame at the bottom makes the lower rows hard to
    /// read; reserve it for the short, "alive" sidebars. Either way the sidebar
    /// gets a trailing hairline so it separates cleanly from the detail pane.
    func warmSidebar(flame: Bool = false) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background {
                ZStack {
                    if flame {
                        LinearGradient(
                            stops: [
                                .init(color: Theme.Color.bgEmberDeep, location: 0.00),
                                .init(color: Theme.Color.bgEmberDeep, location: 0.35),
                                .init(color: Theme.Color.bgEmberMid,  location: 0.70),
                                .init(color: Theme.Color.bgEmberTop,  location: 1.00),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        MetalFlameView()
                            .opacity(0.30)
                            .allowsHitTesting(false)
                        // Wash heaviest at top (where row text needs contrast),
                        // fading to clear at the bottom where the flame sits.
                        LinearGradient(
                            colors: [
                                Theme.Color.bgDeep.opacity(0.55),
                                Theme.Color.bgDeep.opacity(0.20),
                                SwiftUI.Color.clear,
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    } else {
                        Theme.Color.bgMid
                        // Switch which texture is active by changing
                        // `Theme.activeSidebarTexture` below. Both implementations
                        // stay defined so we can A/B compare without rewriting.
                        Theme.activeSidebarTexture.view
                    }
                }
                .ignoresSafeArea()
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Theme.Color.dividerWarm)
                    .frame(width: 0.5)
            }
    }

    /// One call for every `NavigationSplitView` sidebar: the shared resizable
    /// width range (so all sidebars resize identically and default to the same
    /// width) plus the warm treatment (+ optional flame). Apply to the view in
    /// the `sidebar:` closure. HSplitView-based panes (People, Email) can't use
    /// `navigationSplitViewColumnWidth`, so they call `warmSidebar()` directly.
    func sonataSidebar(flame: Bool = false) -> some View {
        self
            .navigationSplitViewColumnWidth(
                min: Theme.Sidebar.minWidth,
                ideal: Theme.Sidebar.idealWidth,
                max: Theme.Sidebar.maxWidth
            )
            .warmSidebar(flame: flame)
    }

    /// Make the window's titlebar match the chrome shell. Applied at the
    /// WindowGroup root so every window opened from the WindowGroup picks it
    /// up. Uses AppKit interop because SwiftUI's `.toolbarBackground(_:for:
    /// .windowToolbar)` does not actually reach the macOS titlebar surface.
    func warmWindowTitlebar() -> some View {
        background(WindowChromeConfigurator())
    }
}

// MARK: - Sidebar texture options
//
// Three flavors of "subtle differentiation between nav rail and sidebar":
//   .gradient  — vertical light-from-above (option 2 — currently liked)
//   .hatch     — fine diagonal lines (option 3 — premium-fabric feel)
//   .noise     — film grain dots (option 1 — tried first, OK but not best)
//
// Flip between them by changing `Theme.activeSidebarTexture` below. All three
// stay defined so we can A/B compare without rewriting.

extension Theme {
    enum SidebarTexture {
        case gradient
        case hatch
        case noise

        @ViewBuilder
        var view: some View {
            switch self {
            case .gradient: WarmGradientOverlay()
            case .hatch:    WarmHatchOverlay()
            case .noise:    WarmTextureOverlay()
            }
        }
    }

    /// The texture currently used by `warmSidebar()`. Change this one line
    /// to flip the entire app's sidebar look.
    static let activeSidebarTexture: SidebarTexture = .hatch

    /// Shared sidebar metrics so every NavigationSplitView sidebar (Sessions,
    /// Workers, Wiki, Files, Studio, …) defaults to the same width and resizes
    /// over the same range. Column width is persisted per scene and shared
    /// across the swapped split-view tabs, so keeping these equal also avoids
    /// "whichever sidebar showed first wins" drift on a fresh launch.
    enum Sidebar {
        static let minWidth: CGFloat = 220
        static let idealWidth: CGFloat = 320
        static let maxWidth: CGFloat = 460
    }
}

/// Option 2 — subtle vertical gradient. Top stop a hint lighter than the
/// bgMid base, fading down. "Implied light from above" depth.
struct WarmGradientOverlay: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: SwiftUI.Color(red: 0.16, green: 0.07, blue: 0.03), location: 0.0),
                .init(color: Theme.Color.bgMid, location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// Option 3 — fine diagonal hatch lines. Static, deterministic, very low
/// opacity. Gives the surface a "premium fabric" feel without leaving the
/// loader's warm palette.
struct WarmHatchOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            // 45° lines, spaced ~6pt apart on the perpendicular. Each line
            // is `y = x - c` for offset `c` ranging over the diagonal extent.
            let spacing: CGFloat = 6
            let strokeStyle = StrokeStyle(lineWidth: 0.5)
            let lineColor = GraphicsContext.Shading.color(.white.opacity(0.045))
            var c: CGFloat = -size.height
            while c <= size.width {
                let x1 = max(0, c)
                let x2 = min(size.width, size.height + c)
                if x2 > x1 {
                    var p = Path()
                    p.move(to: CGPoint(x: x1, y: x1 - c))
                    p.addLine(to: CGPoint(x: x2, y: x2 - c))
                    ctx.stroke(p, with: lineColor, style: strokeStyle)
                }
                c += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Option 1 — film-grain dots. Static, deterministic, very low opacity.
/// ~1200 dots is enough density at typical sidebar widths.
struct WarmTextureOverlay: View {
    /// Deterministic dot positions in normalized [0,1] coords. Computed
    /// once at first access via a seeded LCG so every render of every
    /// sidebar shows the same noise pattern (no shimmer between layouts).
    private static let dots: [CGPoint] = {
        var rng = SeededRNG(seed: 0xC0FFEE_BEEF)
        var pts: [CGPoint] = []
        pts.reserveCapacity(1200)
        for _ in 0..<1200 {
            pts.append(CGPoint(
                x: Double.random(in: 0...1, using: &rng),
                y: Double.random(in: 0...1, using: &rng)
            ))
        }
        return pts
    }()

    var body: some View {
        Canvas { ctx, size in
            let r: CGFloat = 0.5
            for p in Self.dots {
                let x = p.x * size.width
                let y = p.y * size.height
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color(.white.opacity(0.06))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Linear congruential RNG seeded for deterministic noise positions.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// One-shot AppKit configurator: walks up to the hosting NSWindow on first
/// mount, makes the titlebar transparent + draw under the toolbar, and tints
/// the window background to the ember chrome. Idempotent — re-applies on
/// updateNSView in case the window swaps.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(window: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window) }
    }
    private func configure(window: NSWindow?) {
        guard let window else { return }
        // Idempotent guard — only configure once per window. Repeated
        // configuration on every updateNSView was breaking SwiftUI's
        // WindowGroup state restoration.
        if window.titlebarAppearsTransparent { return }
        window.titlebarAppearsTransparent = true
        // NOTE: deliberately NOT inserting `.fullSizeContentView` into the
        // styleMask. Doing so caused SwiftUI's `WindowGroup` to forget the
        // window frame across launches — flipping the styleMask invalidates
        // the saved frame for the prior style. Without it, the titlebar
        // is still transparent and shows the window backgroundColor below;
        // content starts under the titlebar boundary instead of behind it,
        // which is barely noticeable since the colors match.
        window.backgroundColor = NSColor(Theme.Color.bgDeep)

        // Persist + restore the window frame ourselves. SwiftUI's WindowGroup
        // restoration (and even AppKit's setFrameAutosaveName) don't survive our
        // transparent-titlebar interop — the size kept resetting to .defaultSize
        // on every launch. WindowFramePersistence saves the frame to UserDefaults
        // on resize/move and re-asserts the saved frame just after launch to win
        // over SwiftUI re-imposing its default size.
        WindowFramePersistence.shared.attach(to: window)
    }
}

/// Manual main-window frame persistence (see WindowChromeConfigurator). Saves
/// the frame to UserDefaults whenever it changes and restores it on launch,
/// re-asserting once after a short delay because SwiftUI re-applies its default
/// size right after our first restore.
@MainActor
final class WindowFramePersistence {
    static let shared = WindowFramePersistence()

    static let key = "sonata.mainWindowFrame"

    /// Window size used on first launch (and whenever no valid saved frame
    /// exists). Single source of truth for the default dimensions.
    static let defaultSize = CGSize(width: 1300, height: 800)

    private weak var window: NSWindow?
    private var attached = false

    /// The size to open the window at, read from the saved frame if present.
    /// Fed into the scene's `.defaultSize` so the window opens at the restored
    /// size directly — avoiding the flash of opening at the hardcoded default
    /// and then resizing. (Position still settles via `restore()`.)
    static var initialSize: CGSize {
        if let saved = UserDefaults.standard.string(forKey: key) {
            let f = NSRectFromString(saved)
            if f.width >= 400, f.height >= 300 { return CGSize(width: f.width, height: f.height) }
        }
        return defaultSize
    }

    func attach(to window: NSWindow) {
        guard !attached else { return }
        attached = true
        self.window = window

        restore()
        // SwiftUI re-imposes its default size right after we restore, so apply
        // again once its initial layout has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.restore() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(save),
            name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(save),
            name: NSWindow.didMoveNotification, object: window)
    }

    private func restore() {
        guard let window,
              let saved = UserDefaults.standard.string(forKey: Self.key) else { return }
        let frame = NSRectFromString(saved)
        // Guard against a garbage / zero frame locking the window tiny.
        guard frame.width >= 400, frame.height >= 300 else { return }
        window.setFrame(frame, display: true)
    }

    @objc private func save() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.key)
    }
}

// MARK: - Window opacity

extension View {
    /// Bind the hosting window's translucency to `opacity` (0.3…1.0). Driven by
    /// the General-settings slider via `@AppStorage("sonata.windowOpacity")`.
    /// SwiftUI's view opacity can't make the *window* (titlebar + chrome behind
    /// the content) translucent — only AppKit's `NSWindow.alphaValue` does — so
    /// this routes through a small interop view that re-applies whenever the
    /// value changes.
    func windowOpacity(_ opacity: Double) -> some View {
        background(WindowOpacityConfigurator(opacity: opacity))
    }
}

/// Applies `NSWindow.alphaValue` to the hosting window and re-applies on every
/// `updateNSView`, so dragging the opacity slider updates the window live.
/// Clamps to 0.3…1.0 so the window can never become fully invisible / unusable.
private struct WindowOpacityConfigurator: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(to: v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        let clamped = min(max(opacity, 0.3), 1.0)
        if abs(window.alphaValue - clamped) > 0.001 {
            window.alphaValue = clamped
        }
    }
}
