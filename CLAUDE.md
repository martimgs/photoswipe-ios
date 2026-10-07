# CLAUDE.md

Fork of [noluyorAbi/photoswipe-ios](https://github.com/noluyorAbi/photoswipe-ios) (MIT, © 2026 Alperen Adatepe — keep `LICENSE` intact).
Owner of this fork: martimgs.

## Goal

A photo **rating and selection** app. Not a cleanup app.

**The app NEVER deletes photos.** There is no deletion code, trash queue, freed-space
estimate, storage stats, or duplicate detection. "Rejecting" a photo only hides it inside
this app. Do not add any `PHAssetChangeRequest.deleteAssets` call.

UI reference: [`docs/mockup.png`](docs/mockup.png) (4 screens).

### Screen 1 — Library ("My Photos")
- List of albums the user has **connected**: cover thumbnail, name, photo count. Settings gear
  top-right (photo-access status + "Open Settings", app version).
- Last row "Connect Album" opens a sheet with two sources:
  - **Apple Photos** — only real user-created albums. Never "All Photos"/the whole library,
    Recents, smart albums, or shared iCloud albums.
  - **Dropbox** — shown, marked "Coming soon". Dropbox is the planned second source.
- Connections persist between launches. Swipe a row to disconnect — never touches the photos.

### Screen 2/3 — Swipe (rating)
- Header: back, album name, "12 of 842" counter, Undo, "…" menu (min-rating filter, open grid).
- Large rounded photo card, 5-star row below (tap = set exact rating, tap the current star again = clear to 0), scrollable filmstrip
  (tap to jump) at the bottom. No X / heart buttons: the photo gets the space.
- Landscape: the stars move into the header row (album name and count on the left, stars and
  "…" on the right), so the photo fills everything above the full-width filmstrip.
- Gestures apply to the current photo, then advance:
  right = +1 star, left = next (rating unchanged), up = pick (5 stars), down = reject
  (hides the photo **and sets it to 0 stars**; Undo restores the previous rating,
  Restore from the Rejected tab leaves it at 0).
  VoiceOver gets Pick / Reject as actions on the card.
- While dragging, an overlay on the card shows the change (e.g. a large star).
- Tap the card = full screen (zoom/pan). Bottom bar: exposure −1 / +1 EV (preview only,
  never saved) and sticky Instagram crop buttons 4:5 / 1:1 / 9:16 (Stories) / 8:5 (two-post
  carousel, dashed line where it splits); drag/pinch the photo inside the frame. On close, a
  changed crop asks to be saved as a **soft crop** — the photo is never modified; the swipe
  card and grid show the cropped part with a crop badge, and exports add a cropped JPEG copy
  next to the untouched original (an 8:5 crop also as its two 4:5 posts).

### Screen 4 — Grid (review)
- Instagram profile-style grid: 3 columns of 3:4 tiles, 1 pt lines between, edge to edge,
  no spacing. Labels sit on the photo in white like the Photos app: "2★" top left, soft crop
  (crop icon + "4:5") top right. A cropped tile shows the crop (an 8:5 carousel's first post)
  trimmed to 3:4.
- Subtitle shows the active filter, e.g. "84 selected • 4+ stars".
- Tabs: **All**, **Selected** (filtered by min rating), **Rejected** (mockup says "Trash" — use
  "Rejected"). Un-reject from the Rejected tab.
- Sort (in "…"): Album Order, Highest Rated First, Lowest Rated First. Ties keep album order.

### Filtering
- Every photo stays in the pool except rejected ones.
- Min-rating filter 0+ (all) / 1+ / 2+ / 3+ / 4+ / 5 in swipe and grid; always a user choice,
  never automatic.

## Data
- **Ratings** for Apple Photos albums are written to the real asset with the iOS 27 PhotoKit
  API so they show in Photos:
  ```swift
  try await PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest(for: asset).rating = newRating   // PHAsset.Rating, .unset ... .five
  }
  ```
  `PHAsset` is an immutable snapshot — track written ratings locally, and serialize writes per
  asset so an undo can't race the write it undoes.
- **Soft crops** (aspect + normalized rect in the upright photo) live on `PhotoState`.
- **Rejected status and connected albums** live in SwiftData, keyed by (source, photo/album
  identifier), so Dropbox photos can reuse the same model later.
- Deployment target: **iOS 27.0**.

## Out of scope for now
Dropbox integration, export.

## Build

```bash
cd Pickory
xcodebuild -project Pickory.xcodeproj -scheme Pickory \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

That command is for compile checks only. To install on a simulator, build without
`CODE_SIGNING_ALLOWED=NO` (e.g. `-destination 'id=<udid>'`): an unsigned build has no
`application-identifier`, so keychain writes fail and Dropbox sign-in ends in `token_storage_error`.

The project uses Xcode synchronized folders: adding/removing Swift files under
`Pickory/Pickory/` needs no `project.pbxproj` edits. The simulator photo library is nearly
empty; add images with `xcrun simctl addmedia booted <file>`.

## Conventions
- SwiftUI + MVVM, no third-party deps, fully on-device, no networking (until Dropbox).
- All PhotoKit mutations go through `PHPhotoLibrary.performChanges`.
- Light warm off-white UI, minimal type, large rounded cards, black star icons, lots of whitespace.
- Signing: `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` (`com.alperen.Pickory`) are the
  upstream author's — change them before running on a device.
