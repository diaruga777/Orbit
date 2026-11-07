# App icons

Orbit uses solid white MacBook and iPhone silhouettes on solid black, with only
a slight glass finish on the device edges. A very thin flat white orbital arc
tapers to points and stops before the phone on both sides. Device faces have no
internal shading; the orbit has no glass effect.

- iOS master: `Apps/Orbit/Assets.xcassets/AppIcon.appiconset/Orbit.png`
  (1024px, opaque, full bleed; iOS supplies the mask).
- Mac master: `Apps/OrbitMac/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`
  (1024px, transparent outside the rounded black tile).
- The Mac catalog contains the standard 16, 32, 128, 256 and 512pt sizes at 1x/2x.
  Exports are resized with macOS `sips`. The packaging script uses `iconutil` to
  turn those same PNGs into the bundle's `Orbit.icns`.

The Mac menu bar uses `OrbitMenuBarIcon` in `OrbitMacApp.swift`: flat vector
device silhouettes and an open orbit, with no tile, glass or shading. Its AppKit
template image follows the system menu bar appearance.

Edited with the built-in image generation tool; no runtime AI dependency.
The prompts below record the selected revision and its Mac adaptation.

## iOS master prompt

Use case: style-transfer. Edit target: the attached current Orbit iOS app icon. Replace its rendering with an extremely simple black-and-white app icon, keeping only the core composition of one laptop at center and one smaller upright phone at upper right on a diagonal orbit. Solid pure black #000000 full-bleed square background, no gradient anywhere in the background. Laptop and phone are SOLID WHITE minimalist silhouettes: the laptop is a plain white rounded rectangular upright screen with a simple white shallow trapezoid base below it, separated by a small black gap. The phone is a plain solid white rounded rectangle, tilted slightly clockwise. No inner screen outlines, no keyboards, no trackpads, no ports, no buttons, no cameras. Device faces are uniformly white with NO internal shading, no gradient fills, no reflections. Allow ONLY a very slight Liquid Glass effect as a hairline softly beveled rim at the OUTER EDGES of the laptop and phone. Keep the shapes predominantly flat and white. The orbit must be a VERY THIN clean WHITE graphic line, about 2 to 3 pixels wide at 1024px; it is NOT glass, NOT a tube, no bevel, no glow, no shadow. It is a single diagonal elliptical arc around the laptop, OPEN at the phone. Both ends gently narrow to needle-sharp points and stop a clear small gap BEFORE reaching the phone, on its two opposite sides. No line touching the phone and no line behind the phone. Laptop hides the section of line behind itself. Large quiet negative space around the combined symbol, 12 percent outer margins. Precise crisp minimal silhouette design, pure monochrome, exceptionally simple. No blue or other colors, no text, no logos, no decorative elements. Square 1024x1024 production artwork, not a mockup; no pre-rounded canvas corners.

## Mac adaptation prompt

Use case: precise-object-edit. Edit the attached minimalist black-and-white Orbit icon into its matching macOS Dock export. Preserve the white silhouette laptop, white silhouette phone and very thin white tapered orbit line EXACTLY as in the reference, including both small gaps before the phone, and preserve the pure solid black background inside the artwork. Change ONLY the outer export format: scale the complete original square artwork to fit inside a centered black rounded-square tile occupying 82 percent of a 1024x1024 canvas; use clean macOS-style smoothly rounded corners. Outside that black tile is genuinely transparent. Tile is solid pure black, flat, with no bevel, no gradient, no glow, no border, no visible drop shadow. Preserve the extremely simple solid white device silhouettes and their very slight outer-edge glass finish; do not add internal shading or any new details. The orbit remains a flat very thin white graphic line, NEVER glass. No text, no logos, no additional shapes, no mockup. Transparent PNG production asset.
