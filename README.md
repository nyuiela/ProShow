# ProShow

Native Apple church presentation app — **Swift / SwiftUI only** for macOS 14+ and iOS 17+.

**GitHub:** https://github.com/nyuiela/ProShow

ProShow is an **original codebase**. [FreeShow](https://github.com/ChurchApps/FreeShow) (GPL-3.0 Electron/Svelte) and ProPresenter are **product references** for features and import goals only. No FreeShow source is copied here; ProPresenter binaries are never reverse-engineered.

| | |
| --- | --- |
| Display name | **ProShow** |
| Bundle ID | `com.kaleel.proshow` |
| Platforms | macOS 14+, iOS 17+ (multiplatform target) |
| UI | SwiftUI operator desk (ProPresenter-class panes) |
| Repo | https://github.com/nyuiela/ProShow |

## Operator desk (current UI)

Dark charcoal desk with blue selection accents and green Audience/Stage lamps:

1. **Top toolbar** — Search, Text, Theme, Show, Edit, Reflow, Bible, More · Live · Audience/Stage status  
2. **Left** — Library / Playlist / Items + Media sources  
3. **Center** — Slide thumbnail grid + transport/zoom · Media bin strip  
4. **Right** — Program preview, screen target, layer tabs (Props / Master clears, …)

## Open & run on Mac

**Intended checkout:** `~/Documents/tools/ProShow`  
**Requires:** macOS with Xcode 15.4+ (Xcode 16 recommended).

```bash
git clone https://github.com/nyuiela/ProShow.git ~/Documents/tools/ProShow
cd ~/Documents/tools/ProShow
open ProShow.xcodeproj
```

1. Select scheme **ProShow** → **My Mac** (or iOS Simulator).  
2. Run (⌘R).  
3. Click a slide to select; double-click or **Live** / Return to go live; ←/→ to advance; **Show → Open Audience Window** (⇧⌘O).

## Layout

```
ProShow.xcodeproj
ProShow/
  App/
  Models/                  Show + desk sidebar stubs
  Features/Operator/       toolbar, library, slides, media bin, output
  Features/Output/         audience surface + Mac window
  Services/
  Shared/                  ProShowTheme
  Resources/
```

## Licensing

Original Swift work. FreeShow GPL must not be vendored into this tree.
