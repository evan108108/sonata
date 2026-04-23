# Sonata Release Build — Planning Doc

**Status:** Planning (not yet executed)
**Last updated:** 2026-04-23
**Source:** `/Users/evan/memory/Sonata/`
**Target bundle:** `/Applications/Sonata.app`

Goal: stand up a repeatable pipeline that produces a signed, optimized, notarizable Sonata.app, so (a) Launch-at-Login actually works, (b) the app stops getting quarantined / hassled by Gatekeeper, and (c) we can ship the same binary to Scout (or anyone else) without every machine running an ad-hoc build.

---

## 1. Current state

### How today's build works

There is no build script. The workflow is manual:

```bash
cd /Users/evan/memory/Sonata
swift build                                            # debug mode
cp .build/debug/Sonata /Applications/Sonata.app/Contents/MacOS/Sonata
```

The Sonata.app bundle in `/Applications` was hand-assembled. The `Info.plist`, `Resources/AppIcon.icns`, `Resources/bin/{meilisearch,mem}`, and `Resources/web/` are all pre-existing; the only thing swapped in on each iteration is the `MacOS/Sonata` executable.

Current bundle layout:

```
/Applications/Sonata.app/
└── Contents/
    ├── Info.plist                      # com.sona.sonata, 0.2.0, LSUIElement=false
    ├── _CodeSignature/                 # adhoc signature
    ├── MacOS/
    │   └── Sonata                      # 47 MB, Mach-O arm64, debug build
    └── Resources/
        ├── AppIcon.icns                # 1.3 MB
        ├── bin/
        │   ├── meilisearch             # Mach-O arm64 (signed by Meili)
        │   └── mem                     # shell script
        └── web/                        # HTML dashboards (memory.html, tasks.html, …)
```

`codesign -d --verbose=4 /Applications/Sonata.app` confirms:
- `Signature=adhoc`
- `Identifier=Sonata-<hash>`  (adhoc, not a bundle-id-derived identifier)
- `TeamIdentifier=not set`
- `Sealed Resources=none`
- Entitlements: `com.apple.security.get-task-allow=true` only.

### What's broken / painful about the debug build

1. **Launch at Login doesn't work.** `Sources/Views/SettingsView.swift:55–65` calls `SMAppService.mainApp.register()`. `SMAppService` requires a valid code signature that launchd can verify; an ad-hoc signature is rejected (silently on register; the status comes back `.notFound` or `.requiresApproval`). This is the most user-visible breakage.
2. **Debug build is slow.** Swift debug build with GRDB, Hummingbird, SwiftTerm, SwiftUI is ~47 MB and unoptimized. Release build with `-O` is typically 30–50% smaller and materially faster at startup (important because we block on `waitForSonataHTTP`) and for hot paths like scheduler cycles, memory recall, and vector search.
3. **Gatekeeper/quarantine friction on new machines.** Ad-hoc signed apps get the "damaged / cannot verify developer" dialog on first launch on a machine that didn't build them. Scout machine works because the binary was `scp`'d (no quarantine bit) and the Mac sees the adhoc signature; a DMG download would be blocked.
4. **Adhoc-signed apps lose keychain / TCC grants on update.** Each `cp Sonata /Applications/Sonata.app/Contents/MacOS/` invalidates the signature; macOS then treats the "new" app as a different identity for TCC purposes (Full Disk Access, Accessibility, Automation, Network), so prompts re-appear or permissions silently drop.
5. **Notarization impossible.** Apple's notary service rejects ad-hoc signatures outright. Can't distribute outside our own machines.
6. **`com.apple.security.get-task-allow=true`** in `Sonata.entitlements` is a debug-only entitlement that Apple will reject during notarization. It must be removed for release.

---

## 2. What a release build gives us

| Capability | Debug (today) | Release (goal) |
|---|---|---|
| Binary speed | Unoptimized | `swift build -c release` → `-O`, smaller, faster startup |
| Launch at Login (SMAppService) | Silently broken | Works |
| First-launch Gatekeeper UX | Damaged/unverified dialog | Opens cleanly |
| TCC permission persistence across updates | Breaks on every `cp` | Preserved as long as Team ID + bundle ID match |
| Distributable (other machines, open source) | No | Yes (after notarization) |
| Keychain item sharing | Per-adhoc-hash | Stable per Team ID |
| DMG / zip release artifact | N/A | Yes |
| Scout deploy | Copies binary, hope for best | Copy signed .app, signature stays valid |

---

## 3. Blockers (resolve these first)

**Blocker 1: No Developer ID certificate is installed.**
`security find-identity -v -p codesigning` returns `0 valid identities found`. Everything below depends on acquiring one.

What's needed:
- Apple Developer Program membership ($99/yr).
- Create a `Developer ID Application` certificate in the Apple Developer portal (or via Xcode → Settings → Accounts → Manage Certificates → "+" → Developer ID Application).
- Private key stays in login keychain. Back up the .p12 export — if lost, the certificate must be revoked and reissued, and every previously signed build is untrustworthy.

Verify installation:
```bash
security find-identity -v -p codesigning
# Expected: "<hash> \"Developer ID Application: Evan Formicola (TEAMID)\""
```

**Blocker 2: App-specific password for notarytool.**
For notarization we need `notarytool` credentials. Two options:
- **App-specific password** (simplest): appleid.apple.com → Sign-In & Security → App-Specific Passwords → generate one, store it. Team ID is in the Developer portal.
- **App Store Connect API key** (better for CI): create a key in App Store Connect → Users & Access → Keys, download the `.p8`, note Issuer ID and Key ID.

Either way, store credentials in the keychain once:
```bash
xcrun notarytool store-credentials "sonata-notary" \
    --apple-id "evan108108@gmail.com" \
    --team-id "TEAMID" \
    --password "app-specific-password"
```

**Blocker 3: `Sonata.entitlements` has a debug flag.**
Current content:
```xml
<key>com.apple.security.app-sandbox</key><false/>
<key>com.apple.security.get-task-allow</key><true/>
```
`get-task-allow=true` is incompatible with notarization. Fix in step 5.3 below.

---

## 4. Build pipeline — step by step

### 4.1 Prerequisites check

```bash
xcode-select -p                                        # → /Applications/Xcode.app/Contents/Developer
swift --version                                        # ≥ 6.0 (Package.swift requires this)
xcrun --find codesign && xcrun --find notarytool      # both present
security find-identity -v -p codesigning              # must list Developer ID Application
```

### 4.2 Compile the release binary

```bash
cd /Users/evan/memory/Sonata
swift build -c release --arch arm64
# → .build/release/Sonata (~30 MB expected, single-arch Apple Silicon)
```

**Universal binary (optional, for distribution to Intel Macs):**
```bash
swift build -c release --arch arm64 --arch x86_64
# → .build/apple/Products/Release/Sonata (lipo'd universal)
```
Intel support is probably not worth carrying unless we intend to open-source to a broader audience — Scout, dev box, and any new machine are all Apple Silicon. Skip unless needed.

**Resource bundle note:** SwiftPM emits a `Sonata_Sonata.bundle` next to the executable in `.build/release/` because `Package.swift` declares `resources: [.copy(...)]`. That bundle must travel into the .app alongside the binary — see 4.4. `Bundle.module.url(forResource:…)` in `SonataApp.swift:26` reads from it at runtime.

### 4.3 Assemble the .app bundle

Target layout:

```
dist/Sonata.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo                                       # "APPL????"
    ├── MacOS/
    │   └── Sonata
    ├── Resources/
    │   ├── AppIcon.icns
    │   ├── Sonata_Sonata.bundle/                     # SwiftPM resource bundle (web/mcp/worker/supervisor)
    │   │   └── Contents/Resources/{web,mcp,worker,supervisor}/
    │   └── bin/
    │       ├── meilisearch                           # embedded; needs to be re-signed by us
    │       └── mem                                   # shell script; doesn't need signing
    └── _CodeSignature/CodeResources                  # created by codesign
```

Build steps:

```bash
APP=dist/Sonata.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

# 1. Executable
cp .build/release/Sonata                   "$APP/Contents/MacOS/Sonata"

# 2. SwiftPM resource bundle (contains web/, mcp/, worker/, supervisor/)
cp -R .build/release/Sonata_Sonata.bundle  "$APP/Contents/Resources/"

# 3. Info.plist (see 4.3.1 below — may need updating for release)
cp scripts/Info.plist                      "$APP/Contents/Info.plist"

# 4. Icon
cp AppIcon.icns                            "$APP/Contents/Resources/AppIcon.icns"

# 5. PkgInfo
printf "APPL????" >                        "$APP/Contents/PkgInfo"

# 6. Embedded tools
cp /opt/homebrew/bin/meilisearch           "$APP/Contents/Resources/bin/meilisearch"
cp scripts/mem                             "$APP/Contents/Resources/bin/mem"
chmod +x                                   "$APP/Contents/Resources/bin/mem"
```

#### 4.3.1 Info.plist changes for release

The current `/Applications/Sonata.app/Contents/Info.plist` is serviceable but incomplete for a signed/notarized app. Create a canonical source at `/Users/evan/memory/Sonata/scripts/Info.plist` (no such file exists today — create it) containing:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sonata</string>
    <key>CFBundleDisplayName</key><string>Sonata</string>
    <key>CFBundleIdentifier</key><string>com.sona.sonata</string>
    <key>CFBundleVersion</key><string>0.2.0</string>              <!-- build number, bump every build -->
    <key>CFBundleShortVersionString</key><string>0.2.0</string>   <!-- marketing version -->
    <key>CFBundleExecutable</key><string>Sonata</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><false/>                                <!-- true = menubar-only; currently false (dock) -->
    <key>NSHumanReadableCopyright</key><string>© 2026 Evan Formicola</string>

    <!-- Usage strings: required if the code path ever hits the API. Only add entries we actually need. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Sonata uses AppleEvents to activate and quit itself when another instance is detected.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Sonata exposes a local HTTP server on 127.0.0.1 so your dashboard and MCP servers can talk to it.</string>
</dict>
</plist>
```

Open questions on Info.plist:
- **Do we want `LSUIElement=true`?** Right now Sonata is a regular Dock app. If we want a menubar-only experience later, flip this. Not a release-build blocker.
- **Bump `CFBundleVersion` on every build.** Notary service complains if you upload twice with the same version. Easy convention: `0.2.0-<git short sha>` or a monotonic build counter.

### 4.4 Sign nested binaries first, then the app

Code signing is inside-out: every Mach-O under the bundle must be signed before you sign the outer app, or signature validation will fail.

```bash
IDENTITY="Developer ID Application: Evan Formicola (TEAMID)"
ENTITLEMENTS="Sonata.entitlements"                     # see 4.5

# 1. Embedded binaries (MeiliSearch is the only nested Mach-O)
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP/Contents/Resources/bin/meilisearch"

# 2. The app itself (outer seal)
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP"
```

Flags in plain English:
- `--force` — overwrite any existing signature (including the adhoc one from SwiftPM).
- `--options runtime` — enable the hardened runtime. **Required for notarization.**
- `--timestamp` — use Apple's timestamp server (so the signature remains valid after the cert expires). Required for notarization.
- `--entitlements` — attach our entitlements plist. The outer `--entitlements` call is what determines the app's effective entitlements at runtime; the nested sign only needs entitlements if the child process itself asks for them (MeiliSearch doesn't, but re-signing with the same entitlements is fine).

**Verify:**
```bash
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose "$APP"
# Expected: "accepted source=Developer ID"
```

### 4.5 Entitlements for release

Replace the contents of `/Users/evan/memory/Sonata/Sonata.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Not sandboxed — Sonata spawns external processes (Claude, MeiliSearch, bun), reads arbitrary files. -->
    <key>com.apple.security.app-sandbox</key><false/>

    <!-- Required because we embed an unsigned-by-us interpreted runtime (bun), spawn Claude, etc.
         Without this, hardened runtime blocks dlopen of untrusted binaries. -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>

    <!-- Required for SwiftTerm PTY spawning and Process invocations that load dynamic libraries. -->
    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>

    <!-- Outbound network (Anthropic API, OpenAI, AgentMail, notarytool fetches, etc.). -->
    <!-- These two keys are sandbox keys; without sandbox they're advisory, but including them
         is harmless and future-proofs if we sandbox later. -->
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.network.server</key><true/>

    <!-- No get-task-allow. Leaving it out = debugging disabled in release, which is what notary wants. -->
</dict>
</plist>
```

Why each key:
- `app-sandbox=false` — we spawn `claude`, `bun`, `meilisearch`, read the user's home directory freely. Sandboxing would require container redirects and break everything. (Apple allows non-sandboxed apps via Developer ID; only App Store requires sandbox.)
- `allow-unsigned-executable-memory` + `disable-library-validation` — needed because Sonata launches `bun` (interpreter), Claude Code's Bun SEA binary, and anything the user pastes into a worker terminal. Without these, hardened runtime kills child processes that map writable+executable memory or load libraries not signed by Apple/us.
- `allow-dyld-environment-variables` — SwiftTerm and some child processes expect env like `DYLD_FALLBACK_LIBRARY_PATH` to work.
- No `app-sandbox` means we don't technically need the network entitlements, but they're documented and cheap.
- **Drop `get-task-allow`.** This is the one-way door to notarization-safe.

**What we're NOT requesting (and why):**
- Camera, mic, location, contacts — we don't use them.
- `com.apple.security.automation.apple-events` — only needed if we *control* other apps via AppleScript. We do call `existing.activate()` on `NSRunningApplication` for our own singleton, which does *not* need this entitlement.
- Full Disk Access — this is a TCC permission granted at runtime, not an entitlement. User grants in System Settings → Privacy.

### 4.6 Notarize

```bash
# 1. Zip the app for upload (notarytool wants a zip or dmg or pkg)
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Sonata-0.2.0.zip

# 2. Submit and wait
xcrun notarytool submit dist/Sonata-0.2.0.zip \
    --keychain-profile "sonata-notary" \
    --wait
# → "status: Accepted" (or rejects with a log URL — fetch it with notarytool log <id>)
```

Typical notary turnaround: 2–15 minutes. Rejections are usually:
- hardened runtime not enabled (re-sign with `--options runtime`)
- `get-task-allow=true` still in entitlements
- a nested binary wasn't signed
- timestamp missing (re-sign with `--timestamp`)

### 4.7 Staple the notarization ticket

```bash
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# Stapling embeds the ticket so Gatekeeper can verify offline on first launch.
```

After stapling, re-generate the distribution artifact (the zip used for notarization doesn't get the ticket; a freshly zipped .app after stapling does).

### 4.8 Final verification

```bash
# Signature is Developer ID, hardened, notarized
codesign -dvvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags|runtime"
# Expected: Authority=Developer ID Application: Evan Formicola (TEAMID)
#           Authority=Developer ID Certification Authority
#           Authority=Apple Root CA
#           TeamIdentifier=TEAMID
#           flags=0x10000(runtime)

# Gatekeeper accepts it
spctl -a -vv -t execute "$APP"
# Expected: accepted ; source=Notarized Developer ID

# Stapled ticket validates offline
xcrun stapler validate "$APP"
# Expected: The validate action worked!
```

---

## 5. Packaging for distribution

### 5.1 Zip (simplest)

```bash
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Sonata-0.2.0.zip
```

Good enough for Scout deploy and GitHub Releases. Download → unzip → drag to Applications.

### 5.2 DMG (nicer UX, optional)

```bash
# Requires create-dmg (brew install create-dmg) or hdiutil directly.
brew install create-dmg      # one-time

create-dmg \
    --volname "Sonata" \
    --volicon "AppIcon.icns" \
    --window-size 600 400 \
    --icon-size 120 \
    --icon "Sonata.app" 150 180 \
    --app-drop-link 450 180 \
    --hdiutil-quiet \
    dist/Sonata-0.2.0.dmg \
    dist/Sonata.app

# DMGs themselves should be signed + notarized:
codesign --sign "$IDENTITY" --timestamp dist/Sonata-0.2.0.dmg
xcrun notarytool submit dist/Sonata-0.2.0.dmg --keychain-profile "sonata-notary" --wait
xcrun stapler staple dist/Sonata-0.2.0.dmg
```

Defer DMG until we're doing an actual release — zip is fine for dogfooding.

---

## 6. Automation — Makefile

Create `/Users/evan/memory/Sonata/Makefile`:

```makefile
# Sonata build targets. Run from /Users/evan/memory/Sonata/.

IDENTITY      ?= Developer ID Application: Evan Formicola (TEAMID)
NOTARY_PROFILE ?= sonata-notary
VERSION       ?= 0.2.0
BUILD         ?= $(VERSION)-$(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

APP_SRC       = .build/release/Sonata
APP_BUNDLE    = .build/release/Sonata_Sonata.bundle
DIST          = dist
APP           = $(DIST)/Sonata.app
ZIP           = $(DIST)/Sonata-$(VERSION).zip
ENTITLEMENTS  = Sonata.entitlements
INFO_PLIST    = scripts/Info.plist
ICON          = AppIcon.icns

.PHONY: all clean release bundle sign verify notarize staple package deploy-local deploy-scout

all: release

clean:
	rm -rf .build $(DIST)

# 1. Compile
release:
	swift build -c release --arch arm64

# 2. Assemble bundle
bundle: release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/bin
	cp $(APP_SRC) $(APP)/Contents/MacOS/Sonata
	cp -R $(APP_BUNDLE) $(APP)/Contents/Resources/
	cp $(INFO_PLIST) $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP)/Contents/Info.plist
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	printf "APPL????" > $(APP)/Contents/PkgInfo
	# Embedded tools — adjust paths if meilisearch moves
	cp /opt/homebrew/bin/meilisearch $(APP)/Contents/Resources/bin/meilisearch
	chmod +x $(APP)/Contents/Resources/bin/meilisearch

# 3. Sign (nested binaries first, then outer)
sign: bundle
	codesign --force --options runtime --timestamp \
	    --entitlements $(ENTITLEMENTS) --sign "$(IDENTITY)" \
	    $(APP)/Contents/Resources/bin/meilisearch
	codesign --force --options runtime --timestamp \
	    --entitlements $(ENTITLEMENTS) --sign "$(IDENTITY)" \
	    $(APP)

verify: sign
	codesign --verify --deep --strict --verbose=2 $(APP)
	spctl --assess --type execute --verbose $(APP) || true

# 4. Notarize + staple
package: verify
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(APP)
	xcrun stapler validate $(APP)
	rm $(ZIP)
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)

# 5. Install locally (replaces /Applications/Sonata.app)
deploy-local: sign
	osascript -e 'tell application "Sonata" to quit' 2>/dev/null; sleep 2
	rm -rf /Applications/Sonata.app
	cp -R $(APP) /Applications/Sonata.app
	open /Applications/Sonata.app

# 6. Deploy to scout — replaces debug-binary-copy in the deploy-scout skill
deploy-scout: sign
	ssh -o IdentitiesOnly=yes -i ~/.ssh/scout_ed25519 scout@192.168.0.17 \
	    "osascript -e 'tell application \"Sonata\" to quit' 2>/dev/null; sleep 2; rm -rf /Applications/Sonata.app"
	rsync -az -e "ssh -o IdentitiesOnly=yes -i ~/.ssh/scout_ed25519" \
	    $(APP)/ scout@192.168.0.17:/Applications/Sonata.app/
	ssh -o IdentitiesOnly=yes -i ~/.ssh/scout_ed25519 scout@192.168.0.17 \
	    "open /Applications/Sonata.app"
```

Usage:
```bash
make                # swift build -c release
make bundle         # + assemble .app
make sign           # + sign with Developer ID
make verify         # check signature + Gatekeeper
make package        # + notarize + staple + zip
make deploy-local   # replace /Applications/Sonata.app (no notarization required for local install)
make deploy-scout   # replace Sonata on scout machine
```

Daily dev iteration stops at `make deploy-local`. Only do `make package` when cutting a release.

---

## 7. GitHub Actions CI/CD (optional)

If/when we open-source Sonata, a CI pipeline that signs and notarizes on tag push:

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Import signing certificate
        env:
          CERT_P12_BASE64: ${{ secrets.DEVELOPER_ID_CERT_P12 }}
          CERT_PASSWORD:   ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          echo "$CERT_P12_BASE64" | base64 --decode > /tmp/cert.p12
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security import /tmp/cert.p12 -k build.keychain -P "$CERT_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" build.keychain

      - name: Store notary credentials
        env:
          APPLE_ID:         ${{ secrets.APPLE_ID }}
          TEAM_ID:          ${{ secrets.TEAM_ID }}
          APP_PASSWORD:     ${{ secrets.APP_SPECIFIC_PASSWORD }}
        run: |
          xcrun notarytool store-credentials sonata-notary \
              --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"

      - name: Build + sign + notarize
        env:
          IDENTITY: "Developer ID Application: Evan Formicola (${{ secrets.TEAM_ID }})"
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          make package VERSION="$VERSION" IDENTITY="$IDENTITY" NOTARY_PROFILE=sonata-notary

      - name: Upload release asset
        uses: softprops/action-gh-release@v2
        with:
          files: dist/Sonata-*.zip
```

Required secrets:
- `DEVELOPER_ID_CERT_P12` — base64 of exported .p12 (`base64 -i cert.p12 | pbcopy`)
- `DEVELOPER_ID_CERT_PASSWORD` — export password
- `KEYCHAIN_PASSWORD` — anything, used to unlock the temp keychain
- `APPLE_ID` — evan108108@gmail.com
- `TEAM_ID` — 10-char team identifier
- `APP_SPECIFIC_PASSWORD` — from appleid.apple.com

macOS 14 runner is ~$0.08/minute and a full build+notarize is 10–20 min, so ~$1–2 per release. Fine.

---

## 8. What changes in the deploy workflow

**Today** (`~/.claude/skills/deploy-scout/SKILL.md`):
```
1. ls .build/debug/Sonata
2. scp .build/debug/Sonata scout:/Applications/Sonata.app/Contents/MacOS/Sonata
3. ssh scout 'osascript quit && open Sonata.app'
4. curl scout:3211/api/system/ping
```

Copies only the binary into a pre-existing app bundle. Breaks the adhoc signature each time.

**After release pipeline:**
```
1. make sign                                          # build, assemble, sign locally
2. make deploy-scout                                  # rsync whole Sonata.app, restart
3. curl scout:3211/api/system/ping
```

Or, once we have a GitHub Action, scout pulls from a GitHub release:
```bash
ssh scout 'curl -L -o /tmp/Sonata.zip https://github.com/evan108108/sonata/releases/latest/download/Sonata-*.zip && ...'
```

The `deploy-scout` skill should be updated to call `make deploy-scout` instead of hand-rolling the scp/ssh dance. Keep the debug path available behind a `--debug` flag for fast iteration when we don't care about signing.

---

## 9. Open questions & unknowns

1. **TEAMID.** Unknown until the Apple Developer account is set up / confirmed. Will replace every `TEAMID` placeholder in this doc once known.
2. **MeiliSearch version.** We currently copy `/opt/homebrew/bin/meilisearch` into the bundle at build time. That's fine for us, but if we distribute, we should pin to a specific version and check it into the repo (or download + verify SHA during `make bundle`). Currently uses whatever Homebrew has installed on the build machine.
3. **Does MeiliSearch's Homebrew build have hardened-runtime + timestamp?** Probably yes (Homebrew re-signs), but we re-sign it ourselves in the Makefile anyway, so it doesn't matter.
4. **Bun embedding.** We don't currently bundle `bun` itself — MCP scripts run via whatever `bun` is on the user's PATH. If we want Sonata to be fully self-contained for a new machine, we should bundle bun in `Contents/Resources/bin/` too. Adds ~80 MB. Defer.
5. **Launch at Login helper.** `SMAppService.mainApp.register()` registers the main app itself as a login item. This works without a login-helper target. If we later want more control (e.g. a helper that only spawns the daemon, not the UI), we'd add a login-helper target to Package.swift — but right now the current setup is simpler and sufficient.
6. **App Store?** Unlikely — we require non-sandboxed process spawning and arbitrary FS access. Mac App Store distribution would require a serious refactor. Skip.
7. **Scout's Sonata app is adhoc today.** Once we have a signed build, the first `make deploy-scout` will replace scout's Sonata.app entirely. If scout has granted TCC permissions (Full Disk Access, etc.) to the adhoc-signed app, those grants are keyed to the adhoc signature and will not transfer. Scout will need to re-grant on first launch of the signed version. One-time cost.
8. **Versioning strategy.** Bump `CFBundleShortVersionString` on every release tag. Bump `CFBundleVersion` (the build number) on every single notarization attempt — the notary service rejects duplicate version tuples. The Makefile uses `git rev-parse --short HEAD` for CFBundleVersion, which is a decent default.
9. **LSUIElement.** Currently `false` (Sonata shows in Dock). If we want menubar-only behavior later, flip to `true`. Unrelated to release build.

---

## 10. Execution checklist

Pre-flight (one-time):
- [ ] Apple Developer Program membership active ($99/yr)
- [ ] Developer ID Application certificate installed — verify: `security find-identity -v -p codesigning` lists one
- [ ] App-specific password generated + stored via `notarytool store-credentials sonata-notary`
- [ ] Export cert as .p12, back it up somewhere safe (1Password etc.)
- [ ] Grab TEAM_ID from developer portal, update Makefile + this doc

Per-release:
- [ ] Bump `VERSION` in Makefile (or pass `VERSION=0.3.0 make package`)
- [ ] `make clean && make package`
- [ ] Check `dist/Sonata-<version>.zip` size is reasonable (<60 MB)
- [ ] Test-install on a clean machine (or delete `/Applications/Sonata.app` first): `open dist/Sonata-*.zip && cp -R .../Sonata.app /Applications/`
- [ ] Verify Launch at Login actually works: toggle it in Settings → reboot → confirm Sonata auto-opens
- [ ] Verify Claude workers still spawn and register (not affected by signing, but worth sanity-checking after the SwiftPM resource bundle path change)
- [ ] `make deploy-scout` once happy
- [ ] Tag the release in git

Nightly / dev iteration (skips notarization):
- [ ] `make deploy-local` — signed with Developer ID, installs in /Applications, no notary roundtrip. Takes ~30s total.

---

## 11. Summary

The path from "it runs on my machine" to "it runs as a proper macOS app" is four concrete steps:

1. **Get a Developer ID certificate.** This is the only real blocker and the one thing no code change can replace.
2. **Add a Makefile** that does `swift build -c release` → assemble bundle → sign → (notarize) → package.
3. **Clean up `Sonata.entitlements`** — drop `get-task-allow`, add hardened-runtime-compatible keys.
4. **Replace the debug-binary-copy deploy pattern** with a full-bundle rsync of a signed app.

Launch at Login starts working immediately after step 1+3 (the SMAppService code is already in place, it's just being rejected because the signature isn't trustworthy). Everything else is polish.

The actual code change surface in the Sonata repo is small:
- `Sonata.entitlements` — rewrite (step 4.5)
- `scripts/Info.plist` — new file (step 4.3.1)
- `Makefile` — new file (step 6)
- `.github/workflows/release.yml` — new file, optional (step 7)
- `~/.claude/skills/deploy-scout/SKILL.md` — update to call `make deploy-scout`

Source code in `Sources/` does not need to change for the release build to work.
