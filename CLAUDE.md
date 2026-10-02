# CLAUDE.md

Fork of [noluyorAbi/photoswipe-ios](https://github.com/noluyorAbi/photoswipe-ios) (MIT, © 2026 Alperen Adatepe — keep `LICENSE` intact).
Owner of this fork: martimgs.

## Goal

Turn PhotoSwipe from a "keep / trash" cleaner into a **star-rating swipe app** that writes
ratings into the user's Photos library using the iOS 27 PhotoKit rating API.

| Gesture | New behaviour |
|---|---|
| Swipe **right** | +1 star (clamped at 5) |
| Swipe **left** | −1 star (clamped at 0 / unset) |
| Swipe **up** | Set to 5 stars |
| Swipe **down** | Reject (queue for deletion via the existing trash flow) |

Original behaviour being replaced: right = keep, left = trash, up = favorite, down = skip.

## The rating API (verified in the iOS 27.0 SDK, Xcode 27.0)

```swift
// PhotosTypes.h — Swift name PHAsset.Rating, ios(27)
enum PHAsset.Rating: Int { case unset = 0, one, two, three, four, five }

asset.rating                       // PHAsset, read-only
PHAssetChangeRequest(for:).rating  // read-write, inside performChanges
```

Write it the same way the app already writes `isFavorite` in
`PhotoSwipe/PhotoSwipe/Models/PhotoLibraryService.swift`:

```swift
try await PHPhotoLibrary.shared().performChanges {
    PHAssetChangeRequest(for: asset).rating = newRating
}
```

`PHAsset` is an immutable snapshot — after a write, re-fetch the asset (or track the new value
locally) before computing the next +1/−1, otherwise repeated swipes read a stale rating.

## Decisions (implemented)

- **Deployment target is iOS 27.0** — no `#available` gating needed for the rating API.
- **Left on an unrated photo** is a no-op write (stays unset) but still counts as reviewed.
- **Every swipe advances the deck** (one decision per photo).
- **Reject** reuses the pending-trash queue + iOS delete confirmation sheet. Never delete
  without the system confirmation.
- **Undo** restores the exact previous rating (`Decision.rate(_, from:, to:)` stores it).
- **Skip and album are hidden, not removed.** `Decision.skip` / `.album` and their handling in
  the view model are intact; the album button is behind `showAlbumButton` in `SwipeDeckView`.
  Down-swipe now rejects instead of skipping.
- Ratings written this session live in `SwipeDeckViewModel.ratingOverrides`; always read via
  `vm.rating(of:)`, never `asset.rating` directly.

## Project layout (where the changes will land)

- `PhotoSwipe/PhotoSwipe.xcodeproj` — single target, SwiftUI, no third-party dependencies.
- `Models/SwipeAction.swift` — `Decision` enum; add rating cases here.
- `Models/PhotoLibraryService.swift` — all PhotoKit writes; add `setRating`.
- `ViewModels/SwipeDeckViewModel.swift` — `decide(_:)` / `undo()` map decisions to effects.
- `Views/SwipeDeckView.swift` — gesture → decision mapping, action bar buttons.
- `Views/PhotoCardView.swift` — per-direction intent stamps (labels need updating).
- `Views/ReviewView.swift`, `Models/StatsStore.swift` — summary counts (kept/favorited → ratings).
- `promo/` — Remotion promo video; unrelated to the app, ignore.

## Build

```bash
cd PhotoSwipe
xcodebuild -project PhotoSwipe.xcodeproj -scheme PhotoSwipe \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Builds clean as-is with Xcode 27.0 (27A266a). The simulator photo library is nearly empty;
add images with `xcrun simctl addmedia booted <file>`.

## Conventions (from upstream)

- SwiftUI + MVVM, no third-party deps, fully on-device, no networking.
- All library mutations go through `PHPhotoLibrary.performChanges`.
- `PhotoLibraryService.byteSize` uses private KVC (`fileSize`) — fine for personal builds,
  must be replaced before any App Store submission.
- Signing: `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` (`com.alperen.PhotoSwipe`) are the
  upstream author's — change them to your own before running on a device.
