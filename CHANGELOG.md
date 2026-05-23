# Changelog

All notable changes to this project will be documented in this file. See [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [v0.1.0] — 2026-05-23

### Adds

* A canonical, provider-neutral **pipeline IR** with `Trim`, `Background`, `Resize`, `Rotate`, `Flip`, `Border`, `Adjust`, `Colorspace`, `IccTransform`, `Sepia`, `Tint`, `ReplaceColor`, `Posterize`, `Pixelate`, `Blur`, `Sharpen`, `Draw`, `Segment`, `Vignette`, `Fade`, `Rounded`, `DropShadow`, `Opacity`, `Orientation`, `Enhance` ops, plus a `Format` struct for output configuration. The pipeline normaliser enforces a Sharp-style canonical order and per-op no-op detection.

* A pluggable **`Image.Plug.Provider`** behaviour with four implementations out of the box:
  * **Cloudflare Images** — recognises `/cdn-cgi/image/<options>/<source>` and `imagedelivery.net/<account>/<image-id>/<variant-or-options>`; parses the documented option set including a `draw=` URL grammar for overlays.
  * **imgix** — query-string format with the documented option set.
  * **Cloudinary** — `<account>/image/upload/<options>/<source>` with multi-stage chained transforms (flattened to one comma-joined option set in v0.1).
  * **ImageKit** — both URL forms (path-prefix `tr:...` and query-string `?tr=...`).
  * **IIIF Image API 3.0 provider** — targets [Compliance Level 2](https://iiif.io/api/image/3.0/compliance/). Parses the standard `<prefix>/<id>/<region>/<size>/<rotation>/<quality>.<format>` form plus the `<prefix>/<id>/info.json` discovery document. Mount with `forward "/iiif/3", Image.Plug, provider: {Image.Plug.Provider.IIIF, []}`. See `guides/iiif_conformance.md` for the per-segment compliance matrix.

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
