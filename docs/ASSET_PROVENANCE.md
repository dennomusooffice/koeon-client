# Asset provenance

```text
EVENT_ASSETS = 0
UNKNOWN_PROVENANCE_ASSETS = 0
BRAND_LOGO_ICON_ASSETS = 0
ASSET_PROVENANCE_STATUS = READY_WITH_BRAND_ASSETS_DEFERRED
```

The tracked candidate contains no PNG/JPEG/WebP/GIF visual asset, event screenshot, logo or AppIcon. The Xcode project has a source reference for an asset catalog, but no asset-catalog content is tracked. UI colors and system symbols are defined in source and are not separate brand files.

`android/gradle/wrapper/gradle-wrapper.jar` is a build-tool artifact, not a visual/brand asset; it is covered by dependency/build provenance review.

Future logo/icon restoration requires a separate origin, owner, license/trademark and public-safe review. Raw or sanitized event imagery must not be imported through that process.

