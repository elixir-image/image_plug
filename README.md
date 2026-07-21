# Image.Plug

A pluggable Plug-based image server for Elixir. Maps URLs to a canonical image-processing pipeline executed via the [`image`](https://hex.pm/packages/image) library, with named, stored variants. Ships a Cloudflare Images URL provider out of the box.

## Companion: rendering responsive markup

For Phoenix LiveView apps, the [`image_components`](https://hex.pm/packages/image_components) library provides a `<.image>` (and `<.picture>`) component that builds best-practice responsive markup against the same Cloudflare URL grammar `image_plug` parses. The two compose: `image_plug` serves the bytes; `image_components` writes the `<img srcset sizes>` / `<picture type media>` markup that asks for them.

## Why

Pluggable URL grammars mean you can swap your image-CDN's URL syntax (Cloudflare Images, Cloudinary, imgix, ImageKit, IIIF Image API 3.0) without changing the source resolver, the variant store, or the rest of your application. The same canonical pipeline drives every transform.

* **Plug-based** — mounts under any prefix from a `Plug.Router` or a Phoenix endpoint.
* **Streaming** — `image` decodes the source progressively (`Image.open/2` for files; `Image.from_req_stream/2` for HTTP) and the encoder pipes its output through `Plug.Conn.send_chunked/2` + `Plug.Conn.chunk/2` so libvips never materialises the full encoded body in BEAM memory.
* **Cloudflare-compatible** — recognises both `/cdn-cgi/image/<options>/<source>` and `imagedelivery.net/<account>/<image-id>/<variant-or-options>` URL forms; supports the documented option set including `width`, `height`, `fit`, `gravity` (named, compass, and `XxY`), `dpr`, `quality`, `format` (incl. `auto` content-negotiation and `json` metadata), `metadata`, `anim`, `compression`, `background`, `blur`, `sharpen`, `brightness`, `contrast`, `gamma`, `saturation`, `rotate`, `flip`, `trim`, `border`, `segment`, `onerror`, and a `draw=` URL grammar for overlays.
* **Variants** — named, stored pipelines that any URL can reference. Provider-neutral: any provider can resolve `/.../<variant-name>` against the same store. Includes an HTTP admin plug for variant CRUD.
* **Cache-aware** — strong ETag derived from the source's `etag_seed` and the normalised pipeline's fingerprint; `If-None-Match` returns 304 without re-encoding; sensible `Cache-Control` defaults; `Vary: Accept` for `format=auto`.
* **Soft AVIF fallback** — if libvips lacks AVIF write support, requests for `format=avif` encode as WebP and the response is tagged with `x-image-plug-format-fallback: avif->webp`. Detected once at boot.
* **Friendly error policy** — defaults to a placeholder PNG in dev (so broken URLs render visibly in the browser) and to streaming the original source bytes in prod (so a transform bug doesn't break the page).

## Installation

Add `:image_plug` to your dependencies:

```elixir
def deps do
  [
    {:image_plug, "~> 0.1"},
    {:req, "~> 0.5"}  # optional, for the HTTP source resolver
  ]
end
```

The `:image` library is a transitive dependency. Make sure your build has `libvips` 8.x available.

## Quick start

Mount the request plug under your image path and configure a source resolver:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  plug Image.Plug,
    provider: {Image.Plug.Provider.Cloudflare,
               mount: "/img",
               hosted_account_hash: "abc123"},
    source_resolver: {Image.Plug.SourceResolver.Composite,
                      file: [root: Path.expand("priv/static/uploads")],
                      http: [allowed_hosts: ["assets.example.com"]]}

  plug MyAppWeb.Router
end
```

Then a request to `https://example.com/img/cdn-cgi/image/width=600,fit=cover,format=auto/photos/sunset.jpg` resolves the source, runs the pipeline, content-negotiates the format (AVIF → WebP → JPEG fallback), and streams the result.

`Image.Plug` claims only requests under the provider's `:mount` (plus, for Cloudflare, `/cdn-cgi/image/` URLs at the root). **Every other request passes through untouched** to the rest of the endpoint pipeline, so it is safe to place `plug Image.Plug` ahead of `plug MyAppWeb.Router` — your normal routes are unaffected. Give the provider a `:mount` prefix so it only intercepts image URLs. See the [usage guide](https://hexdocs.pm/image_plug/usage.html#mounting-in-phoenix) for the full routing rules.

## Variants

Variants are reusable named pipelines. The hosted URL form `/<account>/<image-id>/<variant-name>` resolves against the configured `Image.Plug.VariantStore`.

Define variants at boot:

```elixir
# config/config.exs
config :image_plug,
  variants: [
    {"thumbnail", "width=200,height=200,fit=cover,format=webp"},
    {"hero",      "width=1600,format=auto,quality=82"}
  ]
```

…or programmatically:

```elixir
Image.Plug.put_variant("thumbnail", "width=200,height=200,fit=cover,format=webp")
{:ok, variant} = Image.Plug.get_variant("thumbnail")
:ok = Image.Plug.delete_variant("thumbnail")
```

The implicit `"public"` variant is always seeded and resolves to the empty pipeline (Cloudflare's "no transforms" default).

## HTTP admin API

Mount `Image.Plug.Admin` under whatever path you protect with auth:

```elixir
forward "/admin/variants",
  to: Image.Plug.Admin,
  init_opts: [provider: Image.Plug.Provider.Cloudflare]
```

Routes mirror Cloudflare's variant API:

| Method   | Path     | Action |
| -------- | -------- | ------ |
| `GET`    | `/`      | List all variants. |
| `GET`    | `/:name` | Fetch one variant. |
| `POST`   | `/`      | Create a variant. 409 on name conflict. |
| `PUT`    | `/:name` | Upsert. |
| `PATCH`  | `/:name` | Partial update. |
| `DELETE` | `/:name` | Delete. |

Bodies use the canonical JSON shape `{"name": ..., "options": ..., "metadata": {...}, "never_require_signed_urls": false}`. The plug does **not** authenticate requests — wrap it in your host's auth pipeline.

## Guides

* [Usage](https://hexdocs.pm/image_plug/usage.html) — mounting `Image.Plug` in Phoenix or `Plug.Router`, configuring provider + source resolver + variant store, error policy, telemetry.

* [Sources](https://hexdocs.pm/image_plug/sources.html) — how source resolution works, the default file resolver, the streaming HTTP resolver, the Composite by-kind dispatcher, and a worked S3-resolver example.

* [Face-aware crops](https://hexdocs.pm/image_plug/face_aware.html) — how `gravity=:face` and `face_zoom` integrate with the optional `:image_vision` dependency, and the URL grammar across the four providers.

* [`image_plug` as a CDN-side service](https://hexdocs.pm/image_plug/cdn_origin.html) — deploying as the origin behind CloudFront / Fastly / Cloudflare / nginx, tuning `Cache-Control` for immutable vs mutable URLs, content-negotiation with `Vary: Accept`, invalidation strategies, and operational concerns.

* Per-CDN conformance: [Cloudflare](https://hexdocs.pm/image_plug/cloudflare_conformance.html), [imgix](https://hexdocs.pm/image_plug/imgix_conformance.html), [Cloudinary](https://hexdocs.pm/image_plug/cloudinary_conformance.html), [ImageKit](https://hexdocs.pm/image_plug/image_kit_conformance.html), [IIIF Image API 3.0](https://hexdocs.pm/image_plug/iiif_conformance.html) — what each provider's URL grammar parses, with a `✅` / `⚠️` / `❌` matrix.

For server-rendered components — `<.image>` and `<.picture>` — see the companion library [`image_components`](https://hex.pm/packages/image_components).

## Configuration reference

`Image.Plug.init/1` accepts:

| Option | Default | Meaning |
| ------ | ------- | ------- |
| `:provider` | _required_ | `{module, opts}` for an `Image.Plug.Provider`. |
| `:source_resolver` | _required_ | `{module, opts}` for an `Image.Plug.SourceResolver`. |
| `:variant_store` | `{Image.Plug.VariantStore.ETS, []}` | `{module, opts}`. |
| `:on_error` | `:auto` | `:auto` \| `:render_error_image` \| `:fallback_to_source` \| `:status_text` \| `:raise` \| `{:status, code}`. See "Error policy" below. |
| `:max_pixels` | `25_000_000` | Soft upper bound on output pixel count. |
| `:request_timeout` | `10_000` | Per-request budget in ms. |
| `:telemetry_prefix` | `[:image_plug]` | Atom list prepended to telemetry event names. |

The provider's own options (passed in the `{module, opts}` tuple) include the mount path. Set `mount:` to the path prefix `Image.Plug` should serve — for example `{Image.Plug.Provider.Cloudflare, mount: "/img"}`. When mounted in a Phoenix endpoint ahead of your router, requests outside that prefix pass through to the router untouched; see [Mounting in Phoenix](https://hexdocs.pm/image_plug/usage.html#mounting-in-phoenix).

## Error policy

`:on_error` controls what happens when the pipeline can't produce a result:

* `:auto` (default) — selects `:render_error_image` in `:dev`/`:test` and `:fallback_to_source` in `:prod`. The selection key is `Application.get_env(:image_plug, :env, Mix.env())` so releases behave correctly.

* `:render_error_image` — generates a 400×300 PNG placeholder with the error tag and message painted on. Returns 200 so the broken image still renders visibly in browsers. `Cache-Control: no-store`.

* `:fallback_to_source` — re-encodes the loaded source image in its source format and streams it. Logs the failure at `:error`. Returns 200 with `x-image-plug-error: <tag>` and `Cache-Control: no-store`. Falls through to `:status_text` if the source itself failed to load.

* `:status_text` — text/plain body, status code mapped from the error tag (`Image.Plug.Error.status/1`), `x-image-plug-error` header.

* `:raise` — propagate the error.

* `{:status, code}` — use the given status code with a text body.

## Telemetry

The plug emits two events per request under the configured `:telemetry_prefix` (default `[:image_plug]`):

* `[:image_plug, :request, :start]` — at request entry. Measurements: `%{system_time}`. Metadata: `%{request_path, provider}`.

* `[:image_plug, :request, :stop]` — at request completion. Measurements: `%{duration}` (monotonic native units). Metadata: `%{request_path, provider, status, error_tag}`.

* `[:image_plug, :request, :exception]` — only fired if a handler raises. Measurements: `%{duration}`. Metadata includes `%{kind, reason, stacktrace}`.

## AVIF support

AVIF requires libvips built with `libheif` plus an AV1 encoder (`libaom` or `librav1e`). On builds without those, requests for `format=avif` are served as WebP with `x-image-plug-format-fallback: avif->webp`. A warning is logged once at startup. Check at runtime with `Image.Plug.Capabilities.avif_write?/0`.

## Caching

Every successful response carries:

* A strong ETag derived from `meta.etag_seed` and the normalised pipeline's fingerprint. Two URLs that differ only in option order produce the same ETag.
* `Cache-Control: public, max-age=3600, stale-while-revalidate=86400` by default. The source resolver can override via `meta.cache_control`.
* `Vary: Accept` so the cache differentiates between content-negotiated formats.

Conditional GET via `If-None-Match` returns 304 without invoking libvips.

## License

Apache-2.0.
