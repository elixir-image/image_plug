# Changelog

All notable changes to this project will be documented in this file. See [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
