# TODO

Follow-ups captured during development. Items here are not blockers for the current milestone but should be addressed before the v0.1 release.

## Streaming pipeline construction — DONE

Aligned `Image.Plug.SourceResolver.File` (now uses `File.stream!(path, 2048, []) |> Image.open()`) and documented the full source→encoder→conn chain in `Image.Plug.Pipeline.Encoder`'s moduledoc, citing the [`stream_image_test.exs`](https://github.com/kipcole9/image/blob/main/test/stream_image_test.exs) reference shape. Added `Image.Plug.StreamingPipelineTest` as a regression that exercises both the verbatim Image-library chain and our plug end-to-end (asserting `conn.state == :chunked`). The encoder stays conn-agnostic (returns `{:stream, Enumerable.t()}`); the plug does the `Plug.Conn.chunk/2` reduce so we keep the conn for header manipulation, error fallbacks, and telemetry — equivalent to what `Image.write(image, conn, suffix: ext)` does internally.

## Operation sequence constraints — DONE

`Image.Plug.Pipeline.Normaliser` rewritten to enforce a Sharp-style canonical order (Trim → Background → Resize → Rotate → Flip → Border → Adjust → Blur → Sharpen → Draw → Segment) regardless of the order the provider emits the ops in. Cardinality enforced for every single-instance op kind. Extended no-op folding (Adjust all-1.0, Sharpen/Blur sigma 0, Flip nil direction, Border/explicit Trim all-zero sides). 13 new regression tests including the explicit "Resize lands before any post-resize op no matter when the user appends it" case the original TODO called out.

## LiveView image-tag component — MOVED to `:image_components`

Spun out into a sibling package at `/Users/kip/Development/image/image_components/` (mix app `:image_components`, module namespace `Image.Component.*` — singular namespace, plural package name to match the existing project slot). The earlier one-line `image_components` placeholder was deleted in the same change. Hard dep on `:phoenix_live_view`. Self-contained — its own Cloudflare URL builder; no dep on `:image_plug` (the two packages share the URL grammar, not code).

Includes the full unpic-style port: layout modes (`:fixed | :constrained | :full_width`) with CLS-prevention CSS, both width-descriptor and density-descriptor srcsets, format-fallback `<picture type>` markup, art-direction `<picture media>` markup (`Image.Component.Picture.picture/1`), and a `:host` option for cross-host CDN setups (mirrors unpic's `domain`).

See `image_components`'s own README and CHANGELOG for any further follow-ups.

## Image sibling library: operations needed by CDN adapters

Captured for the `Image` library author at `../image`. Each CDN adapter in this project surfaces operations that `Image` doesn't (yet) expose as a top-level helper. Implementing these upstream lets the providers map cleanly without dropping into raw `Vix.Vips.Operation` calls or rejecting with `:unsupported_option`.

### Currently worked-around in `image_plug`

* **`Image.gamma/2`** — `Vix.Vips.Operation.gamma(image, exponent: g)` exists but no top-level `Image.gamma/2` wrapper. The Cloudflare and imgix providers both use gamma. The interpreter currently calls Vix directly. A wrapper following the `Image.brightness/2` / `Image.contrast/2` pattern would let the interpreter stay at the `Image.*` layer.

* **Selective EXIF preservation** — encoder options support `strip_metadata: true | false` only. Cloudflare's `metadata=copyright` should preserve only the IPTC copyright field; we currently treat it as `:none` (strip everything). Needs a read-tag-then-write helper in `Image`.

### Needed for full imgix conformance

* **`Image.sepia/1`** — single-pass sepia tone. Imgix `sepia=N` (0-100) is documented; we currently `:unsupported_option` it.

* **`Image.monochrome/2`** — single-colour tint (typically used as a brand-colour overlay). Imgix `monochrome=<hex>`. We approximate today (`Adjust{saturation: 0}` plus a `Background` overlay) but a single op would be cleaner and faster.

* **`Image.enhance/1`** — content-aware automatic enhancement (white balance, tone curve). Imgix `auto=enhance`, Cloudinary `e_improve`, ImageKit `e-enhance`. AI-flavoured but usually a fixed pipeline of contrast/saturation/sharpening adjustments derived from image statistics.

* **EXIF orientation override** — `Image.open/2` auto-rotates per EXIF orientation. Imgix `or=<N>` lets the user override. No clean current path; would need an `:autorotate?` option on `Image.open/2` and a separate `Image.set_orientation/2`.

* **Colour-space conversion as a request-level op** — `Image` has ICC-profile import/export options on `Image.open/2` and `Image.write/3` but no mid-pipeline "convert to sRGB" or "convert to Adobe RGB" helper. Imgix `cs=srgb` / `cs=adobergb1998`, Cloudinary `cs_srgb`. Likely just a thin wrapper over `Operation.icc_transform`.

### Needed for full Cloudinary conformance

* **Vignette** — radial darkening from edges. Cloudinary `e_vignette`. Returns `:unsupported_option` today.

* **Pixelate** — block-size argument (and a face-aware variant). Cloudinary `e_pixelate`, `e_pixelate_faces`. Returns `:unsupported_option` today.

* **Cartoonify / posterize** — level count. Cloudinary `e_cartoonify`. Returns `:unsupported_option` today.

* **Colour-replace** — replace pixels matching a source colour with a target colour, with tolerance. Cloudinary `e_replace_color`. Returns `:unsupported_option` today.

* **Gradient fade overlay** — alpha-gradient fade-out on one or more edges. Cloudinary `e_fade`. Returns `:unsupported_option` today.

* **Auto-quality model** — content-aware quality selection that picks an output quality from image statistics. Cloudinary `q_auto` / `q_auto:eco` / `q_auto:good` / `q_auto:best`. Today we leave the encoder default (85) and set `compression: :fast`; output isn't byte-identical to Cloudinary's hosted `q_auto`.

* **Rounded corners** — rectangular crop with corner radius. Cloudinary `r_<n>` / `r_max`. Not implemented in v0.1.

* **Mid-pipeline opacity** — alpha multiplier as a transform op. Cloudinary `o_<n>`. Not implemented in v0.1.

* **Encoder lossy / progressive flags wired through to libvips** — Cloudinary `fl_lossy` / `fl_progressive` / `fl_force_strip` / `fl_preserve_transparency`. We accept the keys today (silently no-op) but don't honour them at encode time. This is an `image_plug`-side encoder gap, not strictly an `Image` library gap.

### Needed for full ImageKit conformance

The imgix list above (sepia, monochrome, enhance, EXIF orientation override, colour-space conversion) covers most of ImageKit's high-value gaps. ImageKit-specific additions:

* **Drop shadow** — coloured shadow with offset, blur, opacity. ImageKit `e-shadow`. Returns `:unsupported_option` today.

* **Gradient overlay** — composite a colour gradient over the image. ImageKit `e-gradient`. Returns `:unsupported_option` today.

* **Auto-contrast** — content-aware single-toggle contrast bump. ImageKit `e-contrast`. We approximate with `Adjust{contrast: 1.1}` today; a content-aware version (one of the `enhance/1` family) would be sharper.

* **Animated-image trim** — extract a sub-range of frames from an animated WebP or GIF. ImageKit `tr=t-<from>-<to>` for trim. `Image.extract_pages/1` exists; need a paired `extract_frames/3` (or pages-by-time-range).

* **AI-driven calls** — background removal, generative editing, retouch, super-resolution. ImageKit `e-bgremove`, `e-changebg`, `e-edit`, `e-retouch`, `e-upscale`. Probably out of scope for the Image library — these depend on third-party model-serving infrastructure. Document as permanent gaps in the conformance guide rather than attempting to land in `Image`.

* **Encoder lossless / progressive / chroma-subsampling flags** — ImageKit `lo-true`, `pr-true`, `cp-<n>`. Returns `:unsupported_option` today; needs encoder-level support in `Image.write/3` first.

* **Aspect-ratio shortcut** — derive missing dimension from aspect ratio. ImageKit `ar-<W>-<H>`. Could be implemented entirely in the provider if needed (no `Image` change required).

* **Zoom** — face-bound zoom factor. ImageKit `z-<n>`. Likely needs a `face_zoom` extension to the existing `Resize` op (a field already exists; wiring it into the interpreter is the gap).

### Notes

These are all opportunities, not blockers. Each adapter ships with a documented gap matrix (`✅`/`⚠️`/`❌`) so users know what's supported. As `Image` adds helpers, the adapters move ⚠️/❌ entries to ✅.

## Cloudinary CDN provider + adapter — DONE

Shipped in both `image_plug` (`Image.Plug.Provider.Cloudinary` — URL recogniser, options parser, signing, wiring) and `image_components` (`Image.Component.CDN.Cloudinary` — URL builder, signing). 42 unit tests + 10 integration tests on the plug side, 18 unit tests + 2 integration tests on the component side, all passing. SHA-256 wire-format-compatible signing with the in-path `s--<sig>--` segment and 32 url-safe-base64-character truncation. Multi-stage chained transforms recognised but flattened to one comma-joined option set (the v0.1 IR doesn't model chained transforms; documented in the conformance guide as ⚠️). See `guides/cloudinary_conformance.md` for the per-option matrix and the documented gaps.

## ImageKit CDN provider + adapter — DONE

Shipped in both `image_plug` (`Image.Plug.Provider.ImageKit` — URL recogniser, options parser, signing, wiring) and `image_components` (`Image.Component.CDN.ImageKit` — URL builder, signing). 39 unit tests + 10 integration tests on the plug side, 17 unit tests + 2 integration tests on the component side, all passing. HMAC-SHA1 wire-format-compatible signing with `?ik-s=<hex>` and `?ik-t=<unix>`. Both URL forms supported on inbound (path-prefix `tr:...` and query-string `?tr=...`); the component emits the path-prefix form. See `guides/image_kit_conformance.md` for the per-option matrix and the documented gaps.

## Rename to `Image.Plug` — DONE

Mix app renamed `:image_server` → `:image_plug`; module namespace `Image.Server.*` → `Image.Plug.*` (request plug merged into the top-level `Image.Plug` module); supervisor / telemetry prefix / default ETS table / response headers / app env key / log prefix all updated; lib + test directory tree moved; README, CHANGELOG, plans, and TODO updated. The on-disk project directory is still `image_server/` — leave that for whenever the parent repo restructures, or rename in a separate filesystem-only commit.
