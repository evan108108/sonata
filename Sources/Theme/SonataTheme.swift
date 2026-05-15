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
        static let dividerWarm   = SwiftUI.Color(red: 1.0, green: 0.80, blue: 0.55).opacity(0.12)

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
