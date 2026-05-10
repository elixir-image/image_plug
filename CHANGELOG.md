# Changelog

All notable changes to this project will be documented in this file. See [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

* **IIIF Image API 3.0 provider** — fifth URL provider, targeting [Compliance Level 2](https://iiif.io/api/image/3.0/compliance/). Parses the standard `<prefix>/<id>/<region>/<size>/<rotation>/<quality>.<format>` form plus the `<prefix>/<id>/info.json` discovery document. Mount with `forward "/iiif/3", Image.Plug, provider: {Image.Plug.Provider.IIIF, []}`. See `guides/iiif_conformance.md` for the per-segment compliance matrix.

* **`Image.Plug.Pipeline.Ops.Crop`** — new IR op for absolute sub-rectangle extraction. Two coordinate systems via `:units` (`:pixels` or `:percent`); the percentage form resolves against actual source dimensions at apply time, so the same op can be reused across sources of different sizes. Slots into the canonical pipeline order between `Trim` and `Resize`. Used by IIIF's `region` segment and exposed in `image_components`'s `<.image region={…}>` attribute.

* **`Resize.size_pct`** — new field on `Ops.Resize`. When set (a positive number), the interpreter resizes by that percentage of the source dimensions instead of using `width`/`height`. Maps to IIIF's `pct:N` size form.

* **`Format` types `:tiff`, `:jp2`, `:gif`, `:pdf`** — extended encoder support. TIFF and JP2 are gated on capability probes (`Image.Plug.Capabilities.tiff_write?/0` / `jp2_write?/0`); GIF and PDF use the always-bundled libvips writers. Required by IIIF Compliance Level 2.

* **`{:info, info_kind, source}` provider result tag** — new variant on `Image.Plug.Provider.result()` for metadata-document requests. Currently used by the IIIF provider for `info.json`; the plug routes `:info` results to a dedicated handler that loads the source for dimensions, builds the document via `Image.Plug.Provider.IIIF.InfoJson.build/2`, and serialises as `application/ld+json` with appropriate cache and link headers.

* **`Image.Plug.Provider.IIIF.InfoJson`** — builder for IIIF Image Information documents. Advertises supported formats and qualities based on actual libvips capabilities, plus the standard Compliance Level 2 `extraFeatures` set.

* **71 new tests** — 16 IIIF URL parser tests, 29 Options parser tests, 7 round-trip property tests, plus 19 HTTP-level end-to-end tests in `test/image/plug/integration/iiif_end_to_end_test.exs` that boot a real `Image.Plug` server with the IIIF provider mounted, fetch every IIIF URL form, and assert the response decodes to an image of the expected dimensions and content type. The integration suite also covers the `info.json` discovery endpoint (shape + headers + cache directives). Full image_plug suite: 565 tests (was 494).

* **`guides/iiif_conformance.md`** — full IIIF Image API 3.0 conformance matrix: which URL forms parse, which segments map to which IR ops, what we deliberately don't implement, and the compliance level we target.

### Changed

* **`Resize.upscale?` projects to IIIF's `^` size prefix** — the existing IR field `upscale?: true` now produces `^<size>` IIIF URLs and round-trips back. Other providers' projections are unchanged.

* **`Rotate.angle` documentation clarifies arbitrary 0..360 angles** — the IR and interpreter already accepted any angle (libvips affine for non-90° values); only the per-provider URL grammars constrain to 90° multiples (Cloudflare, ImageKit) or arbitrary integers (imgix). IIIF accepts arbitrary integer or fractional angles, all of which round-trip cleanly.

* **Cloudinary `z_<float>` parser** — face-zoom factor in `[0.0, 1.0]` matching `Resize.face_zoom`. Mirrors the existing ImageKit `z-<float>` and Cloudflare `face-zoom=<float>` parsers, giving four-way symmetry for face-aware crops. Round-tripped against `image_components`'s URL projector.

* **`guides/face_aware.md`** — covers the `Image.Plug.FaceAware` seam, the optional `:image_vision` integration, the `face_zoom` semantics (loose-vs-tight padding), and the per-provider URL grammar table.

* **`guides/sources.md`** — explains source resolution end-to-end: the default `SourceResolver.File`, the streaming `SourceResolver.HTTP`, the `Composite` by-kind dispatcher, runtime-config of the upload directory, and a worked S3 resolver example.

* **`guides/cdn_origin.md`** — deploying `image_plug` as the origin behind a CDN (CloudFront, Fastly, Cloudflare) or local cache (nginx). Covers the response-header contract (`ETag`, `Cache-Control`, `Vary: Accept`, `Last-Modified`), tuning for immutable vs mutable URLs, per-CDN recipes, surrogate-key invalidation, variants vs ad-hoc transforms, and operational concerns (cold-cache stampede, request collapsing, capacity planning).

### Changed

* **Test output is now quiet by default.** `test/test_helper.exs` calls `ExUnit.start(capture_log: true)`, so the many intentional `:error` / `:warning` log lines from negative-path coverage (malformed URLs, unsupported options, missing sources) are captured per-test and only surfaced if a test fails. No effect on test semantics.

## v0.1.0 — initial release

A pluggable Plug-based image server for Elixir. URLs map to a canonical image-processing IR executed against `Vix.Vips.Image` via the [`image`](https://hex.pm/packages/image) library, with named stored variants, signed URLs, and a Cloudflare-compatible URL grammar (plus imgix, Cloudinary, and ImageKit providers).

Requires `:image` `~> 0.67`.

### Architecture

* A canonical, provider-neutral **pipeline IR** with `Trim`, `Background`, `Resize`, `Rotate`, `Flip`, `Border`, `Adjust`, `Colorspace`, `IccTransform`, `Sepia`, `Tint`, `ReplaceColor`, `Posterize`, `Pixelate`, `Blur`, `Sharpen`, `Draw`, `Segment`, `Vignette`, `Fade`, `Rounded`, `DropShadow`, `Opacity`, `Orientation`, `Enhance` ops, plus a `Format` struct for output configuration. The pipeline normaliser enforces a Sharp-style canonical order and per-op no-op detection.

* A pluggable **`Image.Plug.Provider`** behaviour with four implementations out of the box:
  * **Cloudflare Images** — recognises `/cdn-cgi/image/<options>/<source>` and `imagedelivery.net/<account>/<image-id>/<variant-or-options>`; parses the documented option set including a `draw=` URL grammar for overlays.
  * **imgix** — query-string format with the documented option set.
  * **Cloudinary** — `<account>/image/upload/<options>/<source>` with multi-stage chained transforms (flattened to one comma-joined option set in v0.1).
  * **ImageKit** — both URL forms (path-prefix `tr:...` and query-string `?tr=...`).

* Each adapter ships with a documented per-option **conformance matrix** (`✅` / `⚠️` / `❌`) under `guides/`.

### Pipeline operations

* **Resize family** — `:contain`, `:cover`, `:crop`, `:pad`, `:scale_down`, `:squeeze` fit modes; gravity (named, compass, focal-point); DPR; aspect-ratio shortcuts (ImageKit `ar-W-H`).

* **Geometry** — rotate (multiples of 90°), flip, trim (border-aware and explicit), border, EXIF orientation override (`Image.set_orientation/2`).

* **Colour** — brightness, contrast, saturation, gamma; sepia (`Image.sepia/2`); single-colour tint (`Image.tint/2`); colourspace conversion (`Image.to_colorspace/2`); ICC-profile-driven conversion via `Ops.IccTransform` (`Image.to_colorspace/3`); colour replace (`Image.replace_color/2`); content-aware enhance (`Image.enhance/2`).

* **Pixel-domain effects** — pixelate (`Image.pixelate/2`); posterize / cartoonify (`Image.posterize/2`); blur and sharpen.

* **Mask & alpha** — vignette (`Image.vignette/2`); fade (`Image.fade/2`); rounded corners via SVG mask (`Image.rounded/2`); drop shadow (`Image.drop_shadow/2`); mid-pipeline opacity (`Image.opacity/2`).

* **Face-aware crop & pixelation** — `Resize{gravity: :face}` (Cloudflare `g=face`, imgix `fit=facearea` / `crop=faces`, Cloudinary `g_face`, ImageKit `fo-face`) pre-crops to the most prominent detected face when the optional [`:image_vision`](https://hex.pm/packages/image_vision) dependency is loaded. `face_zoom` (Cloudflare `face-zoom`, ImageKit `z-`) controls how much context surrounds the face. `Ops.PixelateFaces` (Cloudinary `e_pixelate_faces`) pixelates only the face regions. Without `:image_vision`, face-aware ops fall back to libvips' `:attention` saliency crop or no-op silently — the wire-up never errors on missing dependency.

* **Overlays** — `Draw` op with multi-layer composition; per-layer source resolution, sizing, rotation, and positioning.

* **Output format** — JPEG (baseline + progressive), PNG, WebP, AVIF, JSON (metadata endpoint), `:auto` (Accept-driven negotiation). Per-format encoder flags: `:lossy`, `:progressive`, `:chroma_subsampling`. Selective EXIF preservation via `metadata=:copyright` (preserves copyright + orientation through the strip).

### Streaming & performance

* **Streaming decode** — `Image.open/2` for files, `Image.from_req_stream/2` for HTTP via Req. Source bytes are progressively decoded by libvips.

* **Streaming encode** — `Image.stream!/2` piped through `Plug.Conn.send_chunked/2` so the encoded body never materialises in BEAM memory.

* **AVIF soft fallback** — requests for `format=avif` on libvips builds without libheif/AV1 support encode as WebP and tag the response with `x-image-plug-format-fallback: avif->webp`. Detected once at boot via `Image.Plug.Capabilities.probe/0`.

### Cache & HTTP semantics

* **Strong ETag** derived from the source's `etag_seed` and the normalised pipeline's fingerprint. Conditional `If-None-Match` GETs return `304 Not Modified` without invoking libvips.

* **Sensible defaults** for `Cache-Control` and `Vary: Accept` (the latter on `format=auto`).

### Variants

* **`Image.Plug.VariantStore`** behaviour with an **ETS-backed default**; the implicit `"public"` variant is always seeded.

* **`Image.Plug.VariantStore.Persistence`** behaviour with `Image.Plug.VariantStore.Persistence.File` (JSON-on-disk with atomic writes). Variants hydrate on boot; write-through on every CRUD.

* **`Image.Plug.Admin`** exposes the variant CRUD over HTTP/JSON.

### Security

* **HMAC-SHA256 signed URLs** via `Image.Plug.Signing` and the plug's `:signing` config; supports key rotation and optional `?exp=<unix-seconds>` expiry. URL format wire-compatible with Cloudflare's hosted signed URLs (same `sig` / `exp` parameter names, same algorithm).

* **Provider-specific signing** for imgix (HMAC-SHA256 `?s=`), Cloudinary (SHA-256 `s--<sig>--` in-path segment, 32 url-safe-base64 chars), and ImageKit (HMAC-SHA1 `?ik-s=` + `?ik-t=`). All wire-format-compatible with the hosted services.

### Telemetry & error handling

* **Per-request telemetry** under `[:image_plug, :request, :start | :stop | :exception]`.

* **Friendly error policy**: a placeholder PNG in dev (so broken URLs render visibly in the browser) and a stream of the original source bytes in prod (so a transform bug doesn't break the page).

### Companion library

* For Phoenix LiveView markup that builds against the same URL grammar, see [`image_components`](https://hex.pm/packages/image_components) — `<.image>` and `<.picture>` components with responsive `srcset`, lazy loading, blurhash placeholders, and art-direction.

See [the README](https://hexdocs.pm/image_plug/readme.html) and the [user guide](https://hexdocs.pm/image_plug/usage.html) for setup, configuration, and security guidance. The four `*_conformance.md` guides under `guides/` document per-option support for each provider.
