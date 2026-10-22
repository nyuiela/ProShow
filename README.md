# ProShow

Native **macOS-first** live production desk — Swift / SwiftUI for macOS 14+.

iOS is a secondary target and is not the supported operator surface.

**GitHub:** https://github.com/nyuiela/ProShow

ProShow is an **original codebase**. [FreeShow](https://github.com/ChurchApps/FreeShow) (GPL-3.0 Electron/Svelte) and ProPresenter are **product references** for features and import goals only. No FreeShow source is copied here; ProPresenter binaries are never reverse-engineered.

| | |
| --- | --- |
| Display name | **ProShow** |
| Bundle ID | `com.kaleel.proshow` |
| Platforms | **macOS 14+** (primary). iOS 17+ is compiled but not the operator desk. |
| UI | SwiftUI operator desk (ProPresenter-class panes) |
| Repo | https://github.com/nyuiela/ProShow |

## Operator desk (current UI)

Dark charcoal desk with blue selection accents and green Audience/Stage lamps:

1. **Top toolbar** — Search, Text, Theme, Show, Edit, Reflow, Widgets, More · Live · Audience/Stage status  
2. **Left** — Library / Playlist / Items + Media sources  
3. **Center** — Slide thumbnail grid + transport/zoom · Media bin strip  
4. **Right** — Program preview, screen target, layer tabs (Props / Master clears, …)

Each `OutputScreen` opens its own window. Stage uses the Stage editor document with live current/next/notes/clock tokens.

## Open & run on Mac

**Intended checkout:** `~/Documents/projects/tools/ProShow`  
**Requires:** macOS with Xcode 15.4+ (Xcode 16 recommended) and [just](https://github.com/casey/just).

```bash
git clone https://github.com/nyuiela/ProShow.git ~/Documents/projects/tools/ProShow
cd ~/Documents/projects/tools/ProShow
just build
just start
```

Debug builds can be copied to **`/Applications/ProShow.app`** so Camera, Microphone, and Screen Recording grants survive rebuilds. This is off by default: set `PROSHOW_PIN_DEBUG_APP=1` (or `PROSHOW_STABLE_APP=/other/path.app`) to pin. The existing app goes to the Trash, and a signed Release install is never replaced. DerivedData is only a compile cache.

```bash
just              # list recipes
just build        # Debug build (PROSHOW_PIN_DEBUG_APP=1 pins /Applications/ProShow.app)
just start        # build + launch that app
just test         # unit tests
just clean        # wipe DerivedData (keeps /Applications/ProShow.app)
just xcode        # open ProShow.xcodeproj
just app-path     # print the stable app path
```

Or open the project and Run (⌘R) with scheme **ProShow** → **My Mac**. Click a slide to select; double-click or **Live** / Return to go live; ←/→ to advance; **Show → Open Audience Window** (⇧⌘O). Stage is a separate window per stage output.

## Layout

```
ProShow.xcodeproj
ProShow/
  App/
  Models/
  Features/Operator/       toolbar, library, slides, media bin, output
  Features/Output/         one window per OutputScreen + live stage
  Services/
  Shared/                  ProShowTheme
  Resources/
```

## Guest join (Showroom)

Guests open the Next.js app at `~/Documents/projects/startups/foundry/showroom`. Media goes through **LiveKit**; ProShow stays the desk.

```bash
cd ~/Documents/projects/startups/foundry
just dev showroom            # local: http://127.0.0.1:3461/j/demo
# The desk copies https://room.xfoundrylab.com/j/<room>
```

The desk reads LiveKit credentials from that app’s `.env`.

## Control API

Localhost only: [http://127.0.0.1:55076/docs](http://127.0.0.1:55076/docs) · [openapi.json](http://127.0.0.1:55076/openapi.json)

Stream Deck and Bitfocus Companion modules live in `Integrations/`.

## Release packaging

```bash
./build_release.sh --skip-notarize
```

Produces `build/Release/ProShow.dmg` with hardened-runtime signing. Notarization runs when `AC_NOTARY_PROFILE` exists in the keychain.

## Licensing

Original Swift work. FreeShow GPL must not be vendored into this tree. The NDI SDK is not vendored; ProShow `dlopen`s `libndi` only after live I/O is enabled.
