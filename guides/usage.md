# User guide

A practical end-to-end walkthrough: what to install, how to wire `image_plug` into a Phoenix or `Plug.Router` app, the configuration knobs, security considerations, deployment caveats, and recommended best practices.

For the URL grammar itself, see the conformance guide for whichever provider you're using: [Cloudflare](cloudflare_conformance.md), [imgix](imgix_conformance.md), [Cloudinary](cloudinary_conformance.md), or [ImageKit](image_kit_conformance.md). For per-module API reference, see the generated module docs.

## Contents

* [Quick start](#quick-start)
* [Mounting in Phoenix](#mounting-in-phoenix)
* [Mounting in `Plug.Router`](#mounting-in-plugrouter)
* [Source resolvers](#source-resolvers)
* [Variants](#variants) (including [persistence](#persistence))
* [Caching](#caching)
* [Error handling](#error-handling)
* [Telemetry](#telemetry)
* [Signed URLs](#signed-urls)
* [Security considerations](#security-considerations)
* [Deployment caveats](#deployment-caveats)
* [Best practices](#best-practices)

## Quick start

```elixir
def deps do
  [
    {:image_plug, "~> 0.1"},
    {:req, "~> 0.5"}  # optional, only if you use the HTTP source resolver
  ]
end
```

Make sure `libvips` 8.x is installed on the host (the `image` library wraps it via `vix`). On macOS, `brew install vips`. On Debian/Ubuntu, `apt install libvips-dev`.

Mount the plug, configure a source resolver, you're done:

```elixir
plug Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare, []},
  source_resolver: {Image.Plug.SourceResolver.File,
                    root: Application.app_dir(:my_app, "priv/static/uploads")}
```

A request to `/cdn-cgi/image/width=400,format=webp/photos/sunset.jpg` resolves the source, runs the pipeline, content-negotiates the output format, and streams the result.

Pick the provider that matches the URL grammar your clients speak:

* `Image.Plug.Provider.Cloudflare` — path-segment grammar, `/cdn-cgi/image/<options>/<source>`. Wire-format-compatible with Cloudflare's hosted Images service. See the [Cloudflare conformance guide](cloudflare_conformance.md).

* `Image.Plug.Provider.Imgix` — query-string grammar, `/<source>?w=400&fm=webp`. Wire-format-compatible with imgix's hosted service. See the [imgix conformance guide](imgix_conformance.md).

* `Image.Plug.Provider.Cloudinary` — chained-transform path grammar, `/<account>/image/upload/<transforms>/<source>`. Wire-format-compatible with Cloudinary's hosted service. See the [Cloudinary conformance guide](cloudinary_conformance.md).

* `Image.Plug.Provider.ImageKit` — `tr:`-prefix grammar, `/<endpoint>/tr:<transforms>/<source>` (also accepts `?tr=` query-string form). Wire-format-compatible with ImageKit's hosted service. See the [ImageKit conformance guide](image_kit_conformance.md).

The provider only governs URL parsing and signing — all four share the same canonical pipeline IR, the same source resolvers, and the same renderer.

## Mounting in Phoenix

Mount the plug in your endpoint, before `MyAppWeb.Router`:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  plug Plug.Static, at: "/", from: :my_app, gzip: false, only: ~w(assets fonts images favicon.ico)

  plug Image.Plug,
    provider: {Image.Plug.Provider.Cloudflare,
               mount: "/img",
               hosted_account_hash: "abc123"},
    source_resolver: {Image.Plug.SourceResolver.Composite,
                      file: [root: Application.app_dir(:my_app, "priv/static/uploads")],
                      http: [allowed_hosts: ["assets.example.com"]]}

  # ... session, parsers, etc.
  plug MyAppWeb.Router
end
```

Place `Image.Plug` *after* `Plug.Static` (so static assets win when their paths overlap) and *before* parsers (no body to parse on image requests).

### How requests are routed

`Image.Plug` handles only the requests it recognises as image requests — those under the provider's configured `:mount` (and, for the Cloudflare provider, those carrying the `/cdn-cgi/image/` marker even at the mount root). **Every other request passes straight through untouched.** The rest of your endpoint pipeline — session, parsers, and finally `MyAppWeb.Router` — then handles your normal routes exactly as it would without `image_plug`. A request to `/`, `/users/42`, or `/api/...` never touches image processing.

This is what makes it safe to place `plug Image.Plug` at the top of a Phoenix endpoint, ahead of your router. Two rules follow:

* **Give the provider a `:mount` prefix** (e.g. `mount: "/img"`) so it claims only URLs under that path. Without one, providers whose grammar treats every path as an image source — imgix, and ImageKit's query-string form — would try to serve `/` and every other route. The Cloudflare provider is the exception: it also recognises its `/cdn-cgi/image/` marker at the root, so `mount: ""` is safe with it.

* A **genuinely malformed image URL** *under* the mount — for example `/img/cdn-cgi/image/width=600` with no source segment — is still handled by `Image.Plug`, which returns an error response per your `:on_error` policy rather than passing it through. Passthrough is for requests that are not image requests at all, not for broken ones.

When `Image.Plug` does serve (or error on) a request it **halts** the connection, so nothing further in the pipeline runs for that request. When it passes through, it returns the connection untouched and un-halted, so the next plug runs normally.

If you run `Image.Plug` as the *only* plug of a standalone server (a Bandit `plug:` entry with nothing after it), there is nowhere for a passed-through request to go — add a fallback route (a `Plug.Router` with `forward "/img", to: Image.Plug` and a `match _` that returns 404) if you need to serve non-image paths from the same server. Inside a Phoenix endpoint this never arises, because the router is always downstream.

## Mounting in `Plug.Router`

```elixir
defmodule MyImageServer do
  use Plug.Router
  plug :match
  plug :dispatch

  forward "/img",
    to: Image.Plug,
    init_opts: [
      provider: {Image.Plug.Provider.Cloudflare, []},
      source_resolver: {Image.Plug.SourceResolver.File, root: "priv/uploads"}
    ]
end
```

Then `Bandit.start_link(plug: MyImageServer, port: 4000)` or your supervisor of choice.

### Mounting multiple providers side-by-side

Nothing stops you from running several URL grammars in the same app — mount the plug once per grammar on different paths, with a different `:provider` for each:

```elixir
defmodule MyImageServer do
  use Plug.Router
  plug :match
  plug :dispatch

  forward "/cf",
    to: Image.Plug,
    init_opts: [
      provider: {Image.Plug.Provider.Cloudflare, []},
      source_resolver: {Image.Plug.SourceResolver.File, root: "priv/uploads"}
    ]

  forward "/ix",
    to: Image.Plug,
    init_opts: [
      provider: {Image.Plug.Provider.Imgix, []},
      source_resolver: {Image.Plug.SourceResolver.File, root: "priv/uploads"}
    ]

  forward "/cl",
    to: Image.Plug,
    init_opts: [
      provider: {Image.Plug.Provider.Cloudinary, account: "demo"},
      source_resolver: {Image.Plug.SourceResolver.File, root: "priv/uploads"}
    ]

  forward "/ik",
    to: Image.Plug,
    init_opts: [
      provider: {Image.Plug.Provider.ImageKit, []},
      source_resolver: {Image.Plug.SourceResolver.File, root: "priv/uploads"}
    ]
end
```

Now `/cf/cdn-cgi/image/width=400/photo.jpg`, `/ix/photo.jpg?w=400`, `/cl/demo/image/upload/w_400/photo.jpg`, and `/ik/tr:w-400/photo.jpg` all produce the same bytes from the same source — useful when migrating clients off one URL grammar onto another, or when you genuinely have multiple consumer ecosystems.

## Source resolvers

Every request needs to know where the source bytes come from. `image_plug` ships three resolvers and a dispatcher:

### `Image.Plug.SourceResolver.File`

Reads from a configured root directory.

```elixir
{Image.Plug.SourceResolver.File, root: "/var/lib/uploads"}
```

* `:root` (required) — absolute path. Must exist at boot.
* Path-traversal blocked at two levels (`Image.Plug.Source.path/1` rejects `..`; the resolver re-validates the canonical path is still under root).
* Streaming-friendly decode: passes the file path to `Image.open/2` via `File.stream!(path, 2048, [])`.

### `Image.Plug.SourceResolver.HTTP`

Streams from `http(s)://` URLs via `Image.from_req_stream/2`. Requires the optional `:req` dependency.

```elixir
{Image.Plug.SourceResolver.HTTP, allowed_hosts: ["assets.example.com"]}
```

* `:allowed_hosts` (required) — list of hostnames, or `:any` to disable the allow-list.
* `:timeout` — milliseconds between chunks (default 5000).
* The streaming decode does not surface upstream response headers; `etag_seed` is `sha256(url)`. Document this when you cache.

### `Image.Plug.SourceResolver.Composite`

Dispatches by `Source.kind` to a configured per-kind resolver.

```elixir
{Image.Plug.SourceResolver.Composite,
 file:   [root: "/var/lib/uploads"],
 http:   [allowed_hosts: ["assets.example.com"]],
 hosted: {MyApp.AssetResolver, table: :my_assets}}
```

The `:hosted` value is `{module, options}` — there is no built-in hosted-asset resolver in v0.1. Hosts plug their own asset store in via the `Image.Plug.SourceResolver` behaviour.

## Variants

A variant is a named, stored `Image.Plug.Pipeline`. The hosted URL form `/<account>/<image-id>/<variant>` resolves variants against the configured store.

Seed at boot via app env:

```elixir
# config/config.exs
config :image_plug,
  variants: [
    {"thumbnail", "width=200,height=200,fit=cover,format=webp"},
    {"hero",      "width=1600,format=auto,quality=82"},
    {"avatar",    "width=64,height=64,fit=cover,gravity=face,format=auto"}
  ]
```

Or programmatically at runtime:

```elixir
Image.Plug.put_variant("thumbnail", "width=200,height=200,fit=cover,format=webp")
{:ok, variant} = Image.Plug.get_variant("thumbnail")
{:ok, variants} = Image.Plug.list_variants()
:ok = Image.Plug.delete_variant("thumbnail")
```

The implicit `"public"` variant is always seeded (Cloudflare's "no transforms" default). `Image.Plug.put_variant("public", ...)` overrides it.

### Persistence

By default the ETS variant store is in-memory — variants disappear on restart unless they're seeded from `Application.get_env(:image_plug, :variants)`. To persist runtime CRUD changes (variants created/updated via `Image.Plug.put_variant/3` or the HTTP admin API), configure a persistence backend:

```elixir
plug Image.Plug,
  ...
  variant_store: {Image.Plug.VariantStore.ETS, [
    persistence: {
      Image.Plug.VariantStore.Persistence.File,
      path: "/var/lib/image_plug/variants.json"
    }
  ]}
```

What this does:

* At application boot, before the application-env seeds run, the persistence backend's `load/1` callback hydrates the ETS table from disk.

* After every successful `put` or `delete`, the backend's `write/4` callback writes the change through to the persistent store. Write-through, fire-and-forget — failures are logged at `:warn` but don't fail the originating CRUD call.

The shipped `Image.Plug.VariantStore.Persistence.File` backend is JSON-on-disk with atomic writes (write-temp-then-rename). Suitable for a few thousand variants. For larger or higher-write-rate workloads, write your own backend implementing `Image.Plug.VariantStore.Persistence` (`load/1` + `write/4`); a database-backed implementation is two callbacks plus your own ORM call.

Only variants whose `:options` field is set (i.e. created from a CDN-grammar options string, which the public CRUD API and the HTTP admin both do) round-trip through persistence. Variants built from a `Pipeline` struct directly are skipped with a warning — set the `:options` field too if you want them persisted.

### HTTP admin API

For programmatic CRUD over HTTP, mount `Image.Plug.Admin` under whatever path your auth pipeline guards:

```elixir
forward "/admin/variants",
  to: Image.Plug.Admin,
  init_opts: [provider: Image.Plug.Provider.Cloudflare]
```

Routes mirror Cloudflare's variant API (`GET /`, `GET /:name`, `POST /`, `PUT /:name`, `PATCH /:name`, `DELETE /:name`). Bodies use `{"name": ..., "options": ..., "metadata": {...}, "never_require_signed_urls": false}`. Respond codes: 200/201/400/404/409.

The admin plug does **not** authenticate. Wrap it.

## Caching

Every successful response carries:

* A strong `ETag` derived from `meta.etag_seed` (provided by the source resolver) plus the normalised pipeline's fingerprint plus the chosen output format. Two URLs that differ only in option order produce the same ETag.

* `Cache-Control: public, max-age=3600, stale-while-revalidate=86400` by default. Override per-request by having the source resolver populate `meta.cache_control`.

* `Vary: Accept` so caches differentiate content-negotiated formats.

* `Last-Modified` when the source resolver provides one.

Conditional GET via `If-None-Match` returns 304 *without invoking libvips* — the ETag is computed from cheap inputs (source seed + pipeline fingerprint + format atom).

## Error handling

The `:on_error` config value picks the policy:

* `:auto` (default) — selects `:render_error_image` in `:dev`/`:test`, `:fallback_to_source` in `:prod`. The selection key is `Application.get_env(:image_plug, :env, Mix.env())` so releases behave correctly.

* `:render_error_image` — generates a 400×300 PNG placeholder with the error tag and message painted on. Returns 200 so the broken image renders visibly. `Cache-Control: no-store`. Best for development.

* `:fallback_to_source` — re-encodes the loaded source image in its source format and streams it. Logs the failure at `:error`. Returns 200 with `x-image-plug-error: <tag>` and `Cache-Control: no-store`. Falls through to `:status_text` if the source itself failed to load. Best for production: a transform bug doesn't break the page.

* `:status_text` — text/plain body, status code mapped from the error tag (`Image.Plug.Error.status/1`), `x-image-plug-error` header. Best for APIs / tests.

* `:raise` — propagate the error. Useful in unit tests.

* `{:status, code}` — use the given status code with a text body.

Error tags map to status codes via `Image.Plug.Error.status/1`: `:malformed_url`/`:invalid_option`/`:unknown_option` → 400, `:variant_not_found`/`:source_not_found` → 404, `:variant_already_exists` → 409, `:source_too_large` → 413, `:unsupported_*_format` → 415, `:source_fetch_error` → 502, `:request_timeout` → 504.

## Telemetry

Two events per request under the configured `:telemetry_prefix` (default `[:image_plug]`):

* `[:image_plug, :request, :start]` — at request entry. Measurements: `%{system_time}`. Metadata: `%{request_path, provider}`.

* `[:image_plug, :request, :stop]` — at request completion. Measurements: `%{duration}` in monotonic native units. Metadata: `%{request_path, provider, status, error_tag}`.

* `[:image_plug, :request, :exception]` — only when a handler raises (the plug catches, emits, re-raises). Measurements: `%{duration}`. Metadata: `%{kind, reason, stacktrace}`.

Wire into `:telemetry_metrics` for Prometheus / StatsD:

```elixir
defmodule MyApp.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      summary("image_plug.request.stop.duration",
        unit: {:native, :millisecond},
        tags: [:status, :error_tag]),
      counter("image_plug.request.exception.count")
    ]
  end
end
```

## Signed URLs

When you serve images that should only be accessed by authorised clients, configure the plug's `:signing` option. Every request URL must then carry a signature whose value is `HMAC(secret, path)` (algorithm and parameter name vary per provider):

* Cloudflare provider: HMAC-SHA256, `?sig=<hex>` and optional `?exp=<unix-seconds>`.

* Imgix provider: HMAC-SHA256, `?s=<hex>` and optional `?expires=<unix-seconds>` — and the canonical-string rule prepends the secret to the payload (matching imgix's wire format).

* Cloudinary provider: SHA-256 (truncated to 32 url-safe-base64 chars) over `<transforms>/<source><api-secret>`, inserted as a path segment `s--<sig>--` between the delivery type (`upload`) and the first transform stage. No per-URL expiry parameter.

* ImageKit provider: HMAC-SHA1, `?ik-s=<hex>` and optional `?ik-t=<unix-seconds>`.

### Configuration

```elixir
plug Image.Plug,
  ...
  signing: %{
    keys: [System.fetch_env!("IMAGE_PLUG_SIGNING_KEY")],
    required?: true
  }
```

* `:keys` — non-empty list of secret strings. Verification accepts any key in the list (for rotation); signing helpers always use the first.

* `:required?` — when `true`, an unsigned URL returns 401 `:signature_required`. When `false` (default), unsigned URLs pass through but a *signed* URL with an *invalid* signature still 401s. The default is "defense in depth" — useful during a gradual rollout where some clients haven't been updated yet.

### Generating signed URLs

```elixir
path = "/cdn-cgi/image/width=200,format=webp/photos/sunset.jpg"
signed = Image.Plug.Signing.sign(path, ["my-secret"])
# => "/cdn-cgi/image/width=200,format=webp/photos/sunset.jpg?sig=a1b2..."
```

For client-side rendering via `image_components`, pass the secret to the URL builder via `:signing_keys`. See the [`image_components` user guide](https://hexdocs.pm/image_components/usage.html) for the markup-level integration.

### Expiry

Pass `:expires_at` to bound the URL's validity window:

```elixir
expiry = DateTime.utc_now() |> DateTime.add(3600, :second)
signed = Image.Plug.Signing.sign(path, ["my-secret"], expires_at: expiry)
# => "/cdn-cgi/image/.../sunset.jpg?exp=1735848000&sig=a1b2..."
```

The verifier rejects expired URLs with 401 `:signature_expired`.

### Key rotation

To rotate signing keys without breaking outstanding URLs:

1. Add the new key to the front of `:keys`: `keys: ["new-key", "old-key"]`.
2. Restart the plug. Verification accepts URLs signed with either key; signing helpers use the new key.
3. Wait for the longest expected URL lifetime (typically your CDN cache TTL).
4. Drop the old key from `:keys`.

### Conformance with hosted services

`image_plug`'s signed-URL format is wire-format-compatible with the hosted services it shadows:

* **Cloudflare** — interchangeable with [Cloudflare Images' hosted signed URLs](https://developers.cloudflare.com/images/manage-images/serve-images/serve-private-images/). Same parameter names (`sig`, `exp`), same HMAC-SHA256 algorithm, same canonical-string rule.

* **Imgix** — interchangeable with imgix's hosted signed URLs. Same parameter names (`s`, `expires`), same HMAC-SHA256 algorithm, same secret-prepended canonical-string rule.

* **Cloudinary** — interchangeable with Cloudinary's hosted signed URLs. Same path segment (`s--<sig>--`), same SHA-256 algorithm with 32 url-safe-base64-character truncation, same `<transforms>/<source><api-secret>` canonical-string rule.

* **ImageKit** — interchangeable with ImageKit's hosted signed URLs. Same parameter names (`ik-s`, `ik-t`), same HMAC-SHA1 algorithm.

The HMAC value itself differs only because the signing secret is deployment-specific.

Practical consequence: the same `image_components` markup can target either an `image_plug` deployment or the corresponding hosted service by switching the `:host` config and the signing secret — the URL grammar is identical end to end.

## Security considerations

* **Path traversal**. The `File` resolver rejects `..` segments at two levels (the `Source.path/1` constructor and the resolver's canonical-path check). If you write a custom resolver, replicate this check — never join user-supplied path components into a filesystem path without verifying the result stays under your root.

* **HTTP source allow-list**. The `HTTP` resolver requires an explicit `:allowed_hosts` list. `:any` is supported but only sensible behind your own auth/audit layer. Without an allow-list, a malicious URL can turn your image server into an open proxy that fetches arbitrary internal hostnames.

* **Source size limits**. The HTTP resolver does not yet impose a body-size cap; it relies on whatever limits the configured `Req` request honours. For untrusted sources, configure `Req` (or proxy through a CDN that caps body size) explicitly.

* **AdminPlug authentication**. `Image.Plug.Admin` does not authenticate. Wrap it in your auth pipeline (`plug :require_admin`, basic-auth, OAuth, whatever you use). Anyone who can hit the admin route can create/delete variants.

* **Variant injection**. Variants are stored opaquely. A variant whose pipeline embeds a `draw=` op pointing at an external URL will fetch from that URL on every request. If you accept variant definitions from untrusted users (typically you should not), scrub `draw=` layers or restrict to local sources.

* **`:render_error_image` in production**. The placeholder PNG embeds the error tag and message in plain text. Don't enable in prod for public-facing endpoints unless you're comfortable with that information being visible to clients. The default `:auto` policy picks `:fallback_to_source` in prod for exactly this reason.

* **`max_pixels`**. The plug rejects requests whose computed output exceeds `:max_pixels` (default 25 MP). Lower this if you serve untrusted source URLs — libvips will happily allocate huge buffers for absurd target dimensions.

* **`request_timeout`**. Default 10 s budget per request. Lower for public APIs; raise for batch jobs.

## Deployment caveats

### libvips capability detection

AVIF write support depends on libvips being built with `libheif` plus an AV1 encoder (`libaom` or `librav1e`). On builds without those, `format=avif` requests serve as WebP and the response carries `x-image-plug-format-fallback: avif->webp`. A warning logs once at startup. Check at runtime with `Image.Plug.Capabilities.avif_write?/0`.

If your client code requires AVIF specifically (e.g. you've decided AVIF is your single output format and don't want WebP fallback), validate at boot:

```elixir
unless Image.Plug.Capabilities.avif_write?() do
  raise "this deployment requires libvips built with AVIF write support"
end
```

### Memory

libvips is C; image decode/encode work happens outside the BEAM heap. Two implications:

* The BEAM's per-process heap stays small even for huge images. Don't add memory-tuning workarounds based on Erlang process memory; libvips is the consumer.

* OOMs from libvips look like `:enomem` or NIF crashes, not Erlang errors. Set OS-level limits (cgroups, `ulimit`) if running multiple workers; one libvips operation can spike RSS by 2-4× the source's uncompressed size momentarily.

### Source caching

`image_plug` does *not* cache source bytes (only HTTP-level headers on transformed responses). For high-traffic same-source requests, put a CDN or a `Plug.Static`-style cache in front of `SourceResolver.HTTP`. v0.1 deliberately punts source caching to the host.

### Per-derivative cache

Out of scope for v0.1. Every request re-encodes (subject to the 304 ETag short-circuit). For workloads where the same derivative is requested often and you want to skip the re-encode, cache the response bytes in your own layer (Cachex, a CDN, etc.) keyed by the URL. The per-URL ETag is canonicalised so the same variant always produces the same key.

### Telemetry overhead

The handler emits at most 2 events per request (3 if it raises). Default ExUnit benchmarks show ~5 µs of overhead per request. Negligible for any realistic image-encode workload.

## Best practices

### URL design

* Pick one of: `/cdn-cgi/image/<options>/<source>` (ad-hoc transforms) or `/<account>/<image-id>/<variant>` (curated, stored variants). Mix sparingly — the URL surface is easier to reason about when one form dominates.

* Use named variants for everything user-facing. Ad-hoc URLs are convenient in development but make pricing, caching, and security audits harder at scale.

* Configure `mount: "/img"` (or similar) so `/img/cdn-cgi/image/...` cleanly separates from your application routes.

### Format choice

* `format=auto` is the right default for content images. The `Accept`-header negotiation picks AVIF/WebP/JPEG and `Vary: Accept` lets caches differentiate.

* Specify `format=jpeg` explicitly for hero/LCP images where you want a single canonical URL across all browsers (avoids `Vary` cache fragmentation).

* `format=json` is for metadata extraction, not rendering. Rate-limit it if exposed publicly.

### Quality

* `quality=82` for content images (Cloudflare's documented sweet spot).

* `quality=high` (90) for photography portfolios.

* Don't over-tune. The visual difference between 75 and 85 is invisible to most users; the byte difference is significant.

### `:on_error`

* Stick with `:auto`. It does the right thing in dev (placeholder PNG that surfaces the error in the browser) and prod (fallback to source so a transform bug doesn't blank the page).

* Override to `:status_text` only when you're building an API where the consumer expects HTTP error semantics rather than a fallback image.

### Variants and cache hygiene

* When you change a variant's options, the ETag changes (because the pipeline fingerprint changes). Old caches return 304 against new requests until they expire. Either bump `Cache-Control: max-age` defaults to suit your tolerance for staleness, or rename the variant (`thumbnail` → `thumbnail-v2`) when you want an immediate cache bust.

### Sister package: `image_components`

For Phoenix LiveView apps, install [`image_components`](https://hex.pm/packages/image_components) to render `<.image>` and `<.picture>` markup against the same Cloudflare URL grammar `image_plug` parses. The `:host` option lets you point the component at a different deployment than the one rendering the LiveView, mirroring `unpic`'s `domain` option.

### Mix toolchain

Develop and CI against Elixir 1.20.0-rc.4-otp-28 (the project's pinned toolchain). Library `mix.exs` declares `elixir: "~> 1.17"` so consumers can stay on older Elixir; the floor only constrains downstream apps, not local development.

## Where to go next

* [Cloudflare conformance guide](cloudflare_conformance.md) — option-by-option support matrix for the Cloudflare grammar.
* [Imgix conformance guide](imgix_conformance.md) — option-by-option support matrix for the imgix grammar.
* [Cloudinary conformance guide](cloudinary_conformance.md) — option-by-option support matrix for the Cloudinary grammar.
* [ImageKit conformance guide](image_kit_conformance.md) — option-by-option support matrix for the ImageKit grammar.
* The `Image.Plug` moduledoc — request lifecycle in detail.
* The `Image.Plug.Pipeline` moduledoc — how to build pipelines programmatically.
* The `Image.Plug.Provider` moduledoc — how to write a provider for a different URL grammar.

