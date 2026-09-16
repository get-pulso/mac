# Icon source

`firstlight-icon.svg` is the master for `App/Resources/Assets.xcassets/AppIcon.appiconset`.
`firstlight-mark.svg` is the luminous mark alone, on a transparent ground.

The mark is one closed path: the sun circle (r 44.09) minus the offset moon
circle (r 46.21) gives the crescent, and seven wedges close on convex tips.
30 nodes, no curve fitting — edit the numbers, not the Béziers.

Colour is the Amethyst palette from the onboarding playground
(`playground/onboarding-shader/App/RayPalette.swift`). Those values are
**linear radiance**, not sRGB, so they are gamma-encoded here. The radial
gradient carries the ramp as colour plus `stop-opacity`, so the mark keeps its
falloff on any background rather than only over black.

## Regenerating the app icon

The icon body follows the macOS grid: 824 pt centred in 1024 with a 185.4 pt
corner radius, plus a baked drop shadow. `RayLogo.swift` in the playground
reads `icon-1024.png` and finds the mark by luminance, so that slot must stay
filled.

```sh
rsvg-convert -w 2048 -h 2048 Design/firstlight-icon.svg -o /tmp/master.png
# then add the shadow and downscale into the 10 appiconset slots
xcrun actool App/Resources/Assets.xcassets --compile /tmp/out --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist /tmp/p.plist --errors --warnings
```
