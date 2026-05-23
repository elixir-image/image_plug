# TODO

Post-v0.1.0 feature gaps. Each adapter ships with a documented gap matrix (`✅` / `⚠️` / `❌`) in `guides/<provider>_conformance.md`. The items below would close the remaining `⚠️` / `❌` entries.

## Post-v0.1.0 feature gaps

* **ICC profile aliases** — `Image.to_colorspace/3` is wired through `Ops.IccTransform{profile, intent}` and works when an `IccTransform` op is constructed directly. URL tokens like `cs_adobergb1998` / `cs=adobergb1998` still return `:unsupported_option` because custom-ICC paths are deliberately not synthesised from URL strings. An application-level `:icc_aliases` option could map known URL tokens to local profile paths.

* **AI-driven background removal** — `Image.Background.remove/2` and `Image.Background.mask/2` ship in `:image_vision` (BiRefNet-lite via Ortex). Wire-up follows the same pattern as `Image.Plug.FaceAware`: a new `Ops.RemoveBackground{}` IR op whose interpreter clause delegates to `Image.Background.remove/2` only when `Code.ensure_loaded?(Image.Background)` is true. Maps to ImageKit `e-bgremove` / `e-removedotbg`. Not yet implemented.

* **Auto-quality model** — content-aware quality picker for Cloudinary `q_auto`. Out of scope for `Image`; would need a calibrated heuristic.

* **Animated-image frame trim** — ImageKit `tr=t-<from>-<to>`. Needs `Image.extract_frames/3` or a pages-by-time-range helper in `:image`.

* **Auto-contrast (content-aware)** — ImageKit `e-contrast` is currently approximated as `Adjust{contrast: 1.1}`. A content-aware version (one of the `enhance/1` family) would be sharper.

* **Other AI-driven calls** — super-resolution, generative edits. Permanent `:image` gap (these live in `:image_vision` instead, and only the wire-up pattern from face-aware crops would transplant cleanly).
