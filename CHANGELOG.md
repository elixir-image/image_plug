# Changelog

All notable changes to this project will be documented in this file. See [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Requires

* `:image` `~> 0.67`. The new helpers (`Image.gamma/2`, `Image.sepia/2`, `Image.posterize/2`, `Image.opacity/2`, `Image.tint/2`, `Image.fade/2`, `Image.drop_shadow/2`, `Image.set_orientation/2`, `Image.minimize_metadata/2` with `:keep`, and the `:lossy` / `:progressive` / `:chroma_subsampling` options on `Image.write/3`) are all needed by this release's provider wire-ups.

### Added — IR ops

* `Image.Plug.Pipeline.Ops.Sepia` — `:strength` blend factor in `[0.0, 1.0]`.
* `Image.Plug.Pipeline.Ops.Tint` — single-colour tinted monochrome (`:color` is `[r, g, b]`).
* `Image.Plug.Pipeline.Ops.Opacity` — alpha multiplier in `[0.0, 1.0]`.
* `Image.Plug.Pipeline.Ops.Pixelate` — block-style pixelation (`:scale`).
* `Image.Plug.Pipeline.Ops.Posterize` — tonal quantisation (`:levels` 2..256).
* `Image.Plug.Pipeline.Ops.Rounded` — rounded-corners mask (`:radius` integer or `:max`).
* `Image.Plug.Pipeline.Ops.DropShadow` — soft drop shadow (`:color`, `:opacity`, `:sigma`, `:dx`, `:dy`).
* `Image.Plug.Pipeline.Ops.Fade` — alpha-gradient fade (`:edges`, `:length`).
* `Image.Plug.Pipeline.Ops.Orientation` — EXIF orientation override (`:value` 1..8).
* `Image.Plug.Pipeline.Ops.Vignette` — radial darkening (`:strength`).
* `Image.Plug.Pipeline.Ops.Enhance` — content-aware automatic enhancement (no fields; defaults from `Image.enhance/2`).
* `Image.Plug.Pipeline.Ops.IccTransform` — ICC-profile-driven colourspace conversion (`:profile`, `:intent`). Distinct from the named-mode `Ops.Colorspace`. Wraps `Image.to_colorspace/3`. Provider parsers don't synthesise `IccTransform` from URL strings (custom profile paths shouldn't be URL-controllable); construct it programmatically when composing pipelines.

The pipeline normaliser knows about all twelve, with sensible canonical positions and per-op no-op detection.

### Added — encoder

* `Format` carries `:lossy`, `:progressive`, and `:chroma_subsampling` fields, threaded through to the per-format `Image.write/3` option lists.
* `metadata=:copyright` is now selectively preserved (via `Image.minimize_metadata/2` with `keep: [:copyright, :orientation]`) instead of being silently treated as `:none`. Orientation is always preserved alongside copyright so explicit `or=N` overrides survive the metadata strip.

### Added — providers

* **Cloudflare** — `metadata=copyright` flips ⚠️ → ✅.
* **imgix** — `sepia=N`, `monochrome=<hex>`, `or=N` flip ❌/⚠️ → ✅.
* **Cloudinary** — `e_sepia[:N]`, `e_pixelate[:N]`, `e_cartoonify[:N]`, `e_fade[:N]`, `r_<n>` / `r_max`, `o_<n>`, `fl_lossy`, `fl_progressive` flip ❌/⚠️ → ✅.
* **ImageKit** — `e-shadow[-bl-…_st-…_x-…_y-…_c-…]`, `lo-true|false`, `pr-true|false`, `cp-<n>` flip ❌ → ✅.
* **imgix** — `px=N`, `auto=enhance` flip ❌ / ⚠️ → ✅ / ⚠️.
* **Cloudinary** — `e_vignette[:N]`, `e_improve` / `e_auto_brightness` / `e_auto_color` / `e_auto_contrast` flip ❌ → ✅ / ⚠️.
* **ImageKit** — `e-retouch`, `ar-W-H`, `z-<n>` flip ❌ → ⚠️ / ✅ / ⚠️.

22 conformance entries moved from `❌` / `⚠️` to `✅` / `⚠️` across the four providers.

### Changed

* The `Vix.Vips.Operation.gamma` workaround in `Image.Plug.Pipeline.Interpreter` is replaced with a direct `Image.gamma/2` call.

## v0.1.0 — initial release

### Highlights

A pluggable Plug-based image server for Elixir, with:

* A canonical, provider-neutral pipeline IR (rotate/trim/flip/resize/background/border/adjust/sharpen/blur/draw/format) executed against `Vix.Vips.Image` via the [`image`](https://hex.pm/packages/image) library.

* A `Image.Plug.Provider` behaviour with a Cloudflare Images implementation that recognises both URL forms (`/cdn-cgi/image/...` and `imagedelivery.net/...`) and parses the documented option set, including a `draw=` URL grammar for overlays.

* Streaming decode (`Image.open/2` for files, `Image.from_req_stream/2` for HTTP) and streaming output (`Image.stream!/2` piped through `Plug.Conn.send_chunked/2`).

* Named, stored variants via the `Image.Plug.VariantStore` behaviour with an ETS-backed default; the implicit `"public"` variant is always seeded.

* An `Image.Plug.Admin` exposing the variant CRUD over HTTP/JSON.

* Strong ETag derived from the normalised pipeline's fingerprint; conditional GET 304 without invoking libvips; sensible Cache-Control + Vary defaults.

* AVIF soft fallback to WebP on builds without libheif/AV1 support, probed once at boot.

* Friendly default error policy: a placeholder PNG in dev (so broken URLs render visibly) and a stream of the original source bytes in prod (so a transform bug doesn't break the page).

* Per-request telemetry events under `[:image_plug, :request, :start | :stop | :exception]`.

* HMAC-SHA256 signed URLs via `Image.Plug.Signing` and the plug's `:signing` config; supports key rotation and optional `?exp=<unix-seconds>` expiry. URL format interchangeable with Cloudflare's hosted Images signed URLs (same `sig`/`exp` parameter names, same algorithm).

* Variant persistence via `Image.Plug.VariantStore.Persistence` behaviour; ships with `Image.Plug.VariantStore.Persistence.File` (JSON-on-disk, atomic writes). Hydrates on boot; write-through on every CRUD.

See [the README](https://hexdocs.pm/image_plug/readme.html) and the [user guide](https://hexdocs.pm/image_plug/usage.html) for setup, configuration, and security guidance. The [Cloudflare conformance guide](https://hexdocs.pm/image_plug/cloudflare_conformance.html) documents per-option support.
