# App icons

Orbit uses a stylized glass MacBook, a smaller orbiting iPhone and one elliptical
ring on a deep blue background. This is rendered Liquid Glass inspired artwork.

- iOS master: `Apps/Orbit/Assets.xcassets/AppIcon.appiconset/Orbit.png`
  (1024px, opaque, full bleed; iOS supplies the mask).
- Mac master: `Apps/OrbitMac/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`
  (1024px, transparent outside the rounded tile).
- The Mac catalog contains the standard 16, 32, 128, 256 and 512pt sizes at 1x/2x.
  Exports are resized with macOS `sips`. The packaging script uses `iconutil` to
  turn those same PNGs into the bundle's `Orbit.icns`.

Generated with the built-in image generation tool; no runtime AI dependency.
The prompts below record the final selected artwork and its Mac adaptation.

## iOS master prompt

Use case: logo-brand. Asset type: final app icon master for Orbit, 1024x1024 square. Primary request: minimal tiny stylized iPhone orbiting a MacBook, a clean single orbital line, premium Apple Liquid Glass aesthetic. Composition: one simple open laptop glyph centered, one small upright phone glyph at the upper right riding on a single elegant diagonal elliptical orbit around the laptop. Use bold simple shapes that read beautifully at 32px. The laptop has a blank glass screen, a simple solid wedge base, NO keyboard keys, NO trackpad, NO ports, NO tiny details. The phone has a blank screen and a simple thick rounded rim, no buttons or camera details. The ellipse is a clean smooth glass tube that passes behind the devices at the top and in front at the bottom. Materials: translucent frosted silver-blue glass with softly rounded edges, luminous edge refraction, restrained specular highlights, quiet soft shadows. Rich smooth midnight-to-cobalt blue full-bleed background. Calm, elegant, sculptural, very clean icon design, no photorealistic device rendering. Combined symbol fits entirely within the central 78 percent of canvas with clear space on all four sides. Exactly one laptop, one phone, one orbit. No text, no logos, no stars, no flourishes, no frame, no border, no pre-rounded canvas corners. Full-bleed square asset, not an icon mockup.

## Mac adaptation prompt

Use case: precise-object-edit. Edit the attached Orbit app icon into its macOS Dock export. Preserve the exact existing blue artwork, laptop, phone, glass orbit, lighting and composition without redrawing or changing any interior detail. Change only the outer presentation: fit the existing full square image into a macOS-style rounded-square icon tile occupying 82 percent of a new 1024x1024 canvas, centered horizontally and vertically, with smoothly continuous rounded corners (roughly 22 percent radius). Outside the rounded-square tile must be genuinely transparent, including all canvas corners. Add only a very subtle soft drop shadow beneath the tile. The blue background is preserved INSIDE the rounded square only. No text, no other objects, no mockup, no new effects inside the artwork. Output a transparent-background PNG.

