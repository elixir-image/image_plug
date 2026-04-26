# Plan 0001 — Plug-based image server with pluggable URL providers, starting with Cloudflare Images

Status: draft, awaiting review.

## 1. Goals

* Ship a `Plug`-based image server that accepts an HTTP request, parses the URL into a canonical image-processing pipeline, executes the pipeline against a source image using the [`Image`](https://hex.pm/packages/image) library, and streams the transformed result to the client.

* Make the URL grammar pluggable via a `Provider` behaviour so we can implement multiple vendor URL APIs (Cloudflare Images first, Imgur / imgix / Cloudinary later) without changing the interpreter, the source resolver, the variant store, or the plug pipeline.

* Support named, persisted **variants** — saved canonical pipelines that a request can resolve by name (the same idea as Cloudflare Images variants and imgix "purposes"). Variants are provider-neutral: any provider can resolve `/.../<variant-name>` against the same store.

* Be embeddable: the whole thing is a library that exposes a single `Plug` plus a small set of public modules. Hosts mount it under whatever path they like and supply config (provider, source resolver, variant store, cache strategy).

## 2. Non-goals (for this plan)

* No image *upload* / ingestion API. Source images come from URLs or paths the host already has; the asset-management API surface (Cloudflare's `/images/v1` POST/PATCH/DELETE) is out of scope for v0.1.

* No signed-URL verification, rate limiting, or auth. Hosts wrap the plug in their own auth pipeline.

* No on-disk derivative cache in v0.1 — only HTTP-level caching headers and ETag. A pluggable derivative-cache behaviour is sketched in §13 as a v0.2 extension.

* No Workers-binding-style API surface (the JS `images.draw()` builder). The canonical IR can express overlays; we just don't ship a builder DSL on top of it yet.

## 3. Relationship to `image_plug`

_Historical note:_ this plan was originally drafted under the `image_server` project name and `Image.Server.*` namespace. After the M5/M6 milestones the application was renamed to `:image_plug` and the module namespace to `Image.Plug.*`, reserving `Image.Server` for a future hosted image-service product. References below have been updated; on-disk project directory remains `image_server/` for now.

## 4. Architecture overview

A request flows through five clearly separated stages. Each stage is a public module with a small, documented surface; each is independently testable and independently replaceable.

```
HTTP request
    │
    ▼
┌─────────────────────┐    1. Plug entry point. Holds config (provider, source resolver,
│   Image.Plug  │       variant store, cache strategy). Drives the pipeline below.
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐    2. Provider behaviour. Parses the request URL into either:
│  Provider.parse/2   │         {:variant,  name,    overrides, source_ref}
└─────────┬───────────┘         {:pipeline, %Pipeline{}, source_ref}
          │                  Implementations: Image.Plug.Provider.Cloudflare (v0.1).
          ▼
┌─────────────────────┐    3. Variant resolution. If the request named a variant,
│  VariantStore.get   │       look it up, merge any per-request overrides on top,
└─────────┬───────────┘       and produce a final %Pipeline{}. (Skipped for ad-hoc URLs.)
          │
          ▼
┌─────────────────────┐    4. Source resolution. Fetches the source image bytes
│ SourceResolver.load │       (HTTP, file, S3, hosted-by-id, ...) and opens them
└─────────┬───────────┘       as a Vix.Vips.Image via Image.open/2.
          │
          ▼
┌─────────────────────┐    5. Interpreter. Walks the canonical op list and applies
│ Pipeline.execute    │       the matching Image.* call for each op. Returns a
└─────────┬───────────┘       transformed Vimage plus the desired output format.
          │
          ▼
┌─────────────────────┐    6. Encoder. Serialises to bytes in the chosen format
│ Pipeline.encode     │       and sets Content-Type, Content-Length, ETag, and
└─────────┬───────────┘       Cache-Control on the conn.
          │
          ▼
HTTP response
```

The two pluggable seams that matter most are **Provider** (URL grammar in) and **SourceResolver** (where bytes come from). The canonical `%Pipeline{}` is the lingua franca between them and the interpreter — it is the single thing every provider must produce and the single thing the interpreter knows how to consume.

## 5. Module layout

```
lib/
  image/plug.ex                         # Image.Plug — request entry point + version + variant CRUD helpers.
  image/plug/
    plug.ex                             # Image.Plug — the Plug entry point.
    pipeline.ex                         # %Pipeline{} struct, builders, execute/3.
    pipeline/
      op.ex                             # Shared helpers for op structs.
      ops/
        rotate.ex                       # %Pipeline.Ops.Rotate{angle}
        trim.ex                         # %Pipeline.Ops.Trim{...}
        flip.ex                         # %Pipeline.Ops.Flip{direction}
        resize.ex                       # %Pipeline.Ops.Resize{width, height, fit, gravity, upscale?}
        background.ex                   # %Pipeline.Ops.Background{color}
        adjust.ex                       # %Pipeline.Ops.Adjust{brightness, contrast, gamma, saturation}
        sharpen.ex                      # %Pipeline.Ops.Sharpen{sigma}
        blur.ex                         # %Pipeline.Ops.Blur{sigma}
        draw.ex                         # %Pipeline.Ops.Draw{layers}      (overlay/watermark)
        border.ex                       # %Pipeline.Ops.Border{...}
        format.ex                       # %Pipeline.Ops.Format{type, quality, metadata, anim?, dpr}
      interpreter.ex                    # Reduces %Pipeline{} over a Vimage.
      encoder.ex                        # Vimage + format -> iodata + content_type.
      normaliser.ex                     # Reorders/canonicalises an op list (see §11).
    provider.ex                         # @callback parse/2 + shared types.
    provider/
      cloudflare.ex                     # Image.Plug.Provider.Cloudflare
      cloudflare/
        url.ex                          # /cdn-cgi/image/<options>/<source> + imagedelivery.net forms
        options.ex                      # Per-key parser: width, height, fit, gravity, ...
        draw.ex                         # The draw= sub-grammar (when supported via URL).
    source.ex                           # %Source{kind, ref} struct + helpers.
    source_resolver.ex                  # @callback load/2 -> {:ok, vimage, meta} | {:error, term}
    source_resolver/
      http.ex                           # Default: fetches absolute http(s) URLs (allow-list).
      file.ex                           # Reads from a configured root directory.
      hosted.ex                         # Looks up <account>/<image-id> in a configured store.
    variant_store.ex                    # @callback get/put/delete/list + %Variant{} struct.
    variant_store/
      ets.ex                            # In-memory default; survives within VM lifetime.
      file.ex                           # Optional JSON-on-disk store (v0.2).
    cache.ex                            # ETag computation + Cache-Control helpers.
    error.ex                            # Tagged error types and onerror handling.
test/
  image/plug/
    pipeline_test.exs
    pipeline/interpreter_test.exs
    pipeline/encoder_test.exs
    provider/cloudflare/url_test.exs
    provider/cloudflare/options_test.exs
    variant_store/ets_test.exs
    plug_test.exs
  fixtures/
    images/                             # Small JPEG/PNG/WebP test inputs.
```

Naming convention: every public module has a moduledoc; every public function follows the standard doc template (Arguments / Options / Returns / Examples). Op structs are dumb data — all behaviour lives in `Interpreter`.

## 6. Dependencies and `mix.exs`

Required runtime deps:

* `{:plug, "~> 1.16"}` — the only HTTP-server abstraction we depend on. We do not bundle an adapter; hosts pick `bandit` or `cowboy` themselves.

* `{:image, "~> 0.62"}` — the actual image processing. Provides `Image.open/2`, `Image.thumbnail/3`, `Image.resize/3`, `Image.crop/5`, `Image.rotate/3`, `Image.flip/2`, `Image.sharpen/2`, `Image.blur/2`, `Image.brightness/2`, `Image.contrast/2`, `Image.saturation/2`, `Image.embed/4`, `Image.trim/2`, `Image.compose/3`, `Image.write/3`, etc. (The exact `~>` floor will be set to whatever the lowest version that exposes every function we call is.)

* `{:vix, "~> 0.40"}` — already a transitive dep of `image`, but we type-spec against `Vix.Vips.Image` so we list it explicitly.

Optional / dev deps:

* `{:bandit, "~> 1.5", only: [:dev, :test]}` — for the dev playground / integration tests only.

* `{:plug_cowboy, "~> 2.7", only: [:test]}` — only if a test specifically exercises a Cowboy edge case; otherwise omit.

* `{:req, "~> 0.5", optional: true}` — used by the default `SourceResolver.HTTP` if present. Made `optional: true` so hosts that supply their own resolver don't pay the dep cost. If absent and the HTTP resolver is selected at runtime, raise a clear error at startup.

* `{:ex_doc, "~> 0.34", only: :dev, runtime: false}`

* `{:dialyxir, "~> 1.4", only: [:dev], runtime: false}`

* `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}`

JSON: per the global standards we use the OTP-28 built-in `:json.decode/1` / `:json.encode/1` for the `format=json` Cloudflare endpoint and for the `VariantStore.File` backend. No `jason` dep.

`mix.exs` changes:

* `elixir:` — keep the floor low so this can be consumed as a library. Set `elixir: "~> 1.17"` (currently `~> 1.19`). We develop and CI on 1.20.0-rc.4-otp-28 per the global standards, but the declared floor stays at 1.17 so downstream apps on older Elixir can still pull us in.

* `application/0`: add `mod: {Image.Plug.Application, []}` so we can start the default `VariantStore.ETS` GenServer when the app is included as `:included_applications` or started directly. The supervisor only starts children that are explicitly enabled in config — hosts that bring their own variant store get an empty supervision tree.

* `package/0`: add it now (description, files, licenses, links) so we don't have to retrofit when we publish to Hex.

* `docs/0`: group modules into "Public API" (Plug, Pipeline, Provider, VariantStore, Source, SourceResolver) and "Cloudflare provider" and "Internals".

## 7. Canonical pipeline IR

The IR is a `%Pipeline{}` struct holding an ordered list of operation structs plus a few pipeline-wide settings (output format, metadata policy, error policy). Operations are typed structs, one module per op kind. They are pure data — no behaviour, no protocols — so they serialise cleanly (for the variant store) and pattern-match cleanly (for the interpreter).

```elixir
defmodule Image.Plug.Pipeline do
  defstruct ops: [],
            output: %Image.Plug.Pipeline.Ops.Format{type: :auto, quality: 85, metadata: :copyright},
            on_error: :raise,
            provider: nil   # debug breadcrumb: which provider produced this
end
```

Op structs (one per file under `lib/image/plug/pipeline/ops/`):

```elixir
%Pipeline.Ops.Rotate{angle: 0 | 90 | 180 | 270 | float}
%Pipeline.Ops.Trim{mode: :border | :explicit, color: nil | binary, top: 0, right: 0, bottom: 0, left: 0, threshold: 10}
%Pipeline.Ops.Flip{direction: :horizontal | :vertical | :both}
%Pipeline.Ops.Resize{
  width:    pos_integer | :auto | nil,
  height:   pos_integer | nil,
  fit:      :contain | :cover | :crop | :pad | :scale_down | :squeeze,
  gravity:  :auto | :face | :center | :north | :south | :east | :west
            | :north_east | :north_west | :south_east | :south_west
            | {:xy, x :: float, y :: float},
  upscale?: boolean,
  dpr:      pos_integer
}
%Pipeline.Ops.Background{color: binary}                              # "#fff", "rgba(0,0,0,0.5)", "white"
%Pipeline.Ops.Adjust{brightness: float, contrast: float, gamma: float, saturation: float}
%Pipeline.Ops.Sharpen{sigma: float}                                  # Cloudflare 0..10  -> Image sigma
%Pipeline.Ops.Blur{sigma: float}                                     # Cloudflare 0..250 -> Image sigma
%Pipeline.Ops.Border{color: binary, top: 0, right: 0, bottom: 0, left: 0}
%Pipeline.Ops.Draw{layers: [%Pipeline.Ops.Draw.Layer{}]}             # one or many overlays
%Pipeline.Ops.Format{
  type:      :auto | :avif | :webp | :jpeg | :baseline_jpeg | :png | :json,
  quality:   1..100,
  metadata:  :copyright | :keep | :none,
  anim?:     boolean,
  dpr:       pos_integer
}
```

`Pipeline.Ops.Draw.Layer` mirrors Cloudflare's `draw[]` entry:

```elixir
%Pipeline.Ops.Draw.Layer{
  source:   %Image.Plug.Source{},   # nested source, resolved at execute time
  width:    nil | pos_integer,
  height:   nil | pos_integer,
  fit:      :contain | :cover | :crop | :pad | :scale_down,
  gravity:  ... ,
  opacity:  0.0..1.0,
  repeat:   false | true | :x | :y,
  position: nil
            | {:offset, top: nil | int, right: nil | int, bottom: nil | int, left: nil | int},
  background: nil | binary,
  rotate:   0 | 90 | 180 | 270
}
```

The IR is **provider-neutral**. Cloudflare's `gravity=face` and `gravity=auto` both land as `gravity:` atoms; future providers translate their own grammar onto the same atoms. Any vendor-specific concept that doesn't fit cleanly is added to the IR as a new op or a new field (with sensible defaults), never as a free-form bag.

Two design rules we hold to:

* **No Vix types in the IR.** The IR must be JSON-serialisable for the variant store (modulo the `Source` ref). That means atoms, numbers, strings, lists, and structs of those — never a `Vix.Vips.Image` reference.

* **Order matters.** The IR is an ordered list. The interpreter is a straight `Enum.reduce_while/3` — it does not reorder. Reordering, when needed, is the job of `Pipeline.Normaliser`, which runs once after the provider produces the IR (see §11).

## 8. Provider behaviour

A provider is the URL-grammar adapter. It takes a `Plug.Conn` and the provider's own configuration and returns either a fully-formed pipeline + source reference, or a variant lookup + per-request overrides + source reference.

```elixir
defmodule Image.Plug.Provider do
  @moduledoc """
  Behaviour for URL-API providers. A provider parses an incoming request into
  the canonical pipeline IR plus a `%Source{}` describing where to fetch the
  source image from.

  Providers are stateless: configuration is passed in by the plug.
  """

  alias Image.Plug.{Pipeline, Source}

  @type override :: {atom(), term()}

  @type result ::
          {:pipeline, Pipeline.t(), Source.t()}
          | {:variant,  name :: String.t(), [override()], Source.t()}
          | {:passthrough, Source.t()}      # no transforms; serve the source as-is

  @callback parse(Plug.Conn.t(), options :: keyword()) ::
              {:ok, result()} | {:error, Image.Plug.Error.t()}

  @callback content_type() :: String.t()    # informational, used by docs/tests
end
```

Notes:

* `parse/2` does **not** fetch anything. It is pure URL/header parsing. Source fetching is the `SourceResolver`'s job; variant lookup is the `VariantStore`'s job.

* The `:variant` return is what makes the variant feature provider-neutral. Cloudflare returns `{:variant, "thumbnail", [], source}` for `/<account>/<image-id>/thumbnail`; an Imgur-style provider could return the same shape for `/.../img.jpg?variant=thumbnail` — same downstream code path.

* Per-request overrides (the second element of `:variant`) let a provider express things like "use this variant but force `format=webp`". Cloudflare doesn't do this on the URL form, but it's a clean place to support it for other providers without bolting on extra concepts later.

* `:passthrough` lets a provider say "this URL has no transforms — just stream the source". The plug skips the interpreter and encoder entirely. Useful for source-format pass-through and for `format=auto` fast paths.

* `parse/2` returns a typed `Image.Plug.Error.t()` on failure, never raises. The plug maps that to an HTTP status using the provider's own conventions (Cloudflare: 400 for malformed options, 404 for unknown variant, 415 for unsupported source format).

## 9. Cloudflare provider

`Image.Plug.Provider.Cloudflare` recognises both URL forms documented in [Cloudflare Images URL transforms](https://developers.cloudflare.com/images/transform-images/transform-via-url/).

### 9.1 URL forms

**Remote-image transform** (zone-based):

```
/cdn-cgi/image/<options>/<source>
                ▲         ▲
                │         └── absolute path (/foo/bar.jpg) or absolute URL (https://...)
                └──────────── comma-separated key=value list, at least one entry
```

**Hosted-image delivery**:

```
/<account_hash>/<image_id>/<variant-or-options>
        │            │              │
        │            │              └── either a stored variant name (no `=`),
        │            │                  or a comma-separated options list,
        │            │                  or a flexible-variant signed string (out of v0.1 scope)
        │            └── opaque ID; meaning is up to the SourceResolver
        └── usually constant per deployment; we accept it as the path mount prefix
```

Both forms feed the same options parser. Distinguishing the two is purely a URL-pattern match performed by `Provider.Cloudflare.URL`.

The provider's `init`-time options:

* `:mount` — the path prefix the plug is mounted under. Used to strip a leading segment before parsing. Default: `""`.

* `:hosted_account_hash` — when set, the provider also matches the `imagedelivery.net`-style form and treats the first segment as the account hash. Default: `nil` (only `/cdn-cgi/image/...` form is recognised).

* `:variants_enabled?` — default `true`. If `false`, a path that looks like `<account>/<image-id>/<name>` errors with 404 instead of trying to look up the variant.

### 9.2 Option parser

`Image.Plug.Provider.Cloudflare.Options` parses the `<options>` segment. Splitting is `String.split(opts, ",")`; each entry splits on the first `=`. Keys are case-sensitive (Cloudflare is). Aliases (`f`/`format`, `g`/`gravity`, `h`/`height`, `q`/`quality`, `w`/`width`, `scq`/`slow-connection-quality`) normalise to the canonical name before dispatch.

The parser is a per-key lookup table — one clause per option — so adding a key is a one-line change. Each clause produces zero or more IR ops appended to an accumulator. Unknown keys: by default raise `{:error, %Error{tag: :unknown_option, key: key}}`; a `strict?: false` mode logs and ignores them so we can roll out slowly.

Parameter coverage (every entry from the Cloudflare table; mapping to IR shown):

| URL key | IR effect | Notes |
| --- | --- | --- |
| `width` / `w` | sets `Resize.width` | `auto` → `:auto`; integers must be > 0 |
| `height` / `h` | sets `Resize.height` | integer > 0 |
| `fit` | sets `Resize.fit` | `contain`/`cover`/`crop`/`pad`/`scale-down`/`squeeze` |
| `gravity` / `g` | sets `Resize.gravity` | `auto`/`face`/`left`/`right`/`top`/`bottom`; `XxY` → `{:xy, x, y}` with 0.0..1.0 |
| `dpr` | sets `Resize.dpr` and `Format.dpr` | 1 or 2; we accept up to 3 and clamp to documented range |
| `quality` / `q` | sets `Format.quality` | integer 1..100 or named (`high`=90, `medium-high`=80, `medium-low`=65, `low`=50) |
| `format` / `f` | sets `Format.type` | `auto`/`avif`/`webp`/`jpeg`/`baseline-jpeg`/`json` (+ we add `png`) |
| `metadata` | sets `Format.metadata` | `copyright`/`keep`/`none` |
| `anim` | sets `Format.anim?` | `true`/`false` |
| `compression` | sets `Format` flag | only `fast` documented; stored as `Format.compression` (atom) |
| `background` | appends `%Background{}` | hex / CSS name / rgb()/rgba() — colour parsing in `Image.Plug.Color` |
| `blur` | appends `%Blur{}` | 0..250 → libvips sigma via documented mapping |
| `sharpen` | appends `%Sharpen{}` | 0..10 → libvips sigma |
| `brightness` | folds into `%Adjust{}` | multiplier; 1.0 = no-op |
| `contrast` | folds into `%Adjust{}` | multiplier |
| `gamma` | folds into `%Adjust{}` | multiplier |
| `saturation` | folds into `%Adjust{}` | multiplier; 0 = greyscale |
| `rotate` | appends `%Rotate{}` | 90/180/270 only per docs; we also accept multiples of 90 and reject the rest |
| `flip` | appends `%Flip{}` | `h`/`v`/`hv` |
| `trim` | appends `%Trim{}` | `border` for auto-trim; `top;right;bottom;left` for explicit |
| `border` | appends `%Border{}` | sub-grammar `color=#hex;width=N` or per-side; documented Workers-only — we still parse |
| `segment` | appends `%Pipeline.Ops.Segment{kind: :foreground}` | new op; v0.2 (interpreter no-ops in v0.1) |
| `slow-connection-quality` / `scq` | sets `Format.scq_quality` | informational; v0.1 doesn't act on Save-Data, but the field is preserved |
| `zoom` / `face-zoom` | sets `Resize.face_zoom` | only meaningful with `gravity=face`; v0.2 |
| `onerror` | sets `Pipeline.on_error` | only `redirect` documented; we map to `:redirect_to_source` |
| `draw` | appends `%Draw{}` with one `%Layer{}` | URL form: `draw=url(...);width=N;...` per the JSON shape, semicolon-separated; multiple `draw=` entries → multiple layers |

### 9.3 Distinguishing variants from options

For the hosted form `/<account>/<image-id>/<tail>`, `<tail>` is treated as a variant name iff it contains no `=` character (Cloudflare's documented rule). Otherwise it is parsed as an options list. An empty `<tail>` is treated as the implicit `public` variant per Cloudflare docs.

### 9.4 Source reference produced

* For `/cdn-cgi/image/<options>/<source>` where `<source>` starts with `http://` or `https://`: `%Source{kind: :url, ref: <source>}`.

* For `/cdn-cgi/image/<options>/<source>` where `<source>` is an absolute path: `%Source{kind: :path, ref: <source>}`.

* For the hosted form: `%Source{kind: :hosted, ref: {account_hash, image_id}}`.

The host's `SourceResolver` decides what each kind means (file root, allow-list of hostnames, S3 bucket, asset DB lookup, etc.). The Cloudflare provider does not couple to any of that.

## 10. Source resolver behaviour

```elixir
defmodule Image.Plug.SourceResolver do
  @moduledoc """
  Resolves a `%Image.Plug.Source{}` reference into an open `Vix.Vips.Image`
  plus metadata (content_type, etag_seed, last_modified) used downstream for
  HTTP cache headers.
  """

  alias Image.Plug.Source

  @type meta :: %{
          required(:content_type) => String.t(),
          required(:etag_seed)    => binary(),    # any stable per-source bytes
          optional(:last_modified) => DateTime.t(),
          optional(:byte_size)     => non_neg_integer()
        }

  @callback load(Source.t(), options :: keyword()) ::
              {:ok, Vix.Vips.Image.t(), meta()} | {:error, Image.Plug.Error.t()}
end
```

Default implementations shipped:

* **`SourceResolver.File`** — maps `%Source{kind: :path, ref: "/foo/bar.jpg"}` onto a configured `:root` directory, refusing path traversal (`..` segments rejected before joining). Metadata: file mtime, byte size, content type sniffed by `Image.open/2`'s magic-byte detection.

* **`SourceResolver.HTTP`** — fetches `%Source{kind: :url, ref: ...}` via `Req` (declared optional). Configurable allow-list of hostnames, max body size, request timeout, follow-redirect cap. ETag seed is the response `ETag` header if present, otherwise `Last-Modified`, otherwise a SHA-256 of the body.

* **`SourceResolver.Hosted`** — for `%Source{kind: :hosted, ref: {account, image_id}}`. Default impl looks the pair up in a configured ETS table populated by the host. Hosts that store assets in S3 / Postgres / a CDN replace this with their own module.

* **`SourceResolver.Composite`** — dispatches by `Source.kind` to one of the above. The plug uses this by default so a single config value handles every URL form Cloudflare generates.

Two cross-cutting concerns:

* **Streaming-preferred decode.** Each resolver chooses the most streaming-friendly decode path the underlying source allows. `SourceResolver.File` passes the path straight to `Image.open/2`, letting libvips mmap or progressively decode rather than slurping the file into a binary first. `SourceResolver.HTTP` uses `Image.from_req_stream/2` so the body flows from the socket into libvips chunk-by-chunk, bounded by `:max_body_size`. `SourceResolver.Hosted` delegates to whichever transport the host registered (often the file resolver under the hood). The `meta` map is populated from cheap headers (`Content-Type`, `ETag`, `Last-Modified`) without a second pass over the body.

* **Source caching**: out of scope for v0.1. If the same source URL is requested often, the host puts a CDN or `Plug.Static`-style cache in front of `SourceResolver.HTTP`. We document this rather than building it.

## 11. Interpreter

`Image.Plug.Pipeline.Interpreter.execute/2` walks the (normalised) op list and applies the matching `Image.*` call for each op. It is a single `Enum.reduce_while/3` with one `apply_op/2` clause per op struct.

```elixir
def execute(%Pipeline{ops: ops}, %Vimage{} = image) do
  Enum.reduce_while(ops, {:ok, image}, fn op, {:ok, acc} ->
    case apply_op(op, acc) do
      {:ok, next}      -> {:cont, {:ok, next}}
      {:error, _} = e  -> {:halt, e}
    end
  end)
end
```

The mapping table from canonical op → `Image` call (these are what each `apply_op/2` clause does):

| Op | `Image` call |
| --- | --- |
| `%Rotate{angle: a}` | `Image.rotate(image, a)` (skip if `a == 0`) |
| `%Trim{mode: :border, threshold: t}` | `Image.trim(image, threshold: t)` |
| `%Trim{mode: :explicit, top: t, ...}` | `Image.crop(image, l, t, w - l - r, h - t - b)` after computing remaining w/h |
| `%Flip{direction: :horizontal}` | `Image.flip(image, :horizontal)` |
| `%Flip{direction: :vertical}` | `Image.flip(image, :vertical)` |
| `%Flip{direction: :both}` | `Image.flip(image, :horizontal)` then `:vertical` |
| `%Resize{fit: :scale_down}` | `Image.thumbnail(image, "WxH", crop: :none, resize: :down)` |
| `%Resize{fit: :contain}`    | `Image.thumbnail(image, "WxH", crop: :none, resize: :both)` |
| `%Resize{fit: :cover, gravity: g}` | `Image.thumbnail(image, "WxH", crop: gravity_to_crop(g))` |
| `%Resize{fit: :crop}`       | as `:cover`, but `resize: :down` (no upscale) |
| `%Resize{fit: :pad}`        | thumbnail with `crop: :none` then `Image.embed(_, w, h, background_color: bg)` |
| `%Resize{fit: :squeeze}`    | `Image.resize(image, w / source_w, vertical_scale: h / source_h)` |
| `%Background{color: c}`     | flatten transparency: `Image.flatten(image, background: c)` (or compose over a solid colour image) |
| `%Adjust{brightness: b, contrast: c, gamma: g, saturation: s}` | chain `Image.brightness/2`, `Image.contrast/2`, `Image.gamma/2` (if exposed; otherwise libvips op via `Vix`), `Image.saturation/2`, skipping the no-op cases (`1.0`) |
| `%Sharpen{sigma: s}` | `Image.sharpen(image, sigma: s)` |
| `%Blur{sigma: s}`    | `Image.blur(image, sigma: s)` |
| `%Border{...}` | composite the source onto a larger background via `Image.embed/4` |
| `%Draw{layers: ls}` | for each layer: if the layer source is SVG (or can be expressed as SVG — e.g. solid colour fills, simple shapes, text watermarks), render via `Image.from_svg/2` so the overlay scales without raster artefacts; otherwise resolve the nested `%Source{}`, decode it, optionally resize, then `Image.compose/3` at the computed position with the layer's opacity |
| `%Format{...}` | not handled here — consumed by the encoder |
| `%Pipeline.Ops.Segment{}` | v0.1 logs `:not_implemented` and returns `{:ok, image}` (placeholder) |

`gravity_to_crop/1` translates the IR's gravity atoms onto `Image.thumbnail/3`'s `:crop` enum values (`:center`, `:north`, `:south`, …, `:attention` for `:auto`, `:entropy` for an explicit alternative). The `{:xy, x, y}` form is implemented as a thumbnail-then-explicit-crop because libvips' `thumbnail` doesn't take a free-form focal point.

### 11.1 Normalisation

Cloudflare specifies a fixed processing order (rotate → trim → flip → resize → fit → gravity-crop → background → format → quality/effects). The Cloudflare provider produces ops in roughly that order already, but we don't rely on that — `Pipeline.Normaliser.normalise/1` runs after the provider and:

* Reorders ops to a canonical order so that two requests producing the same set of ops in different syntactic orders hash to the same ETag.

* Folds adjacent `%Adjust{}` ops into one.

* Drops no-op ops (rotate 0, blur sigma 0, brightness 1.0, …) so they don't affect the ETag or waste libvips work.

* Validates op cardinality (e.g. only one `%Format{}` per pipeline; multiple raise).

The normaliser is idempotent. The interpreter assumes its input is already normalised.

## 12. Encoder and response

`Image.Plug.Pipeline.Encoder.encode/3` takes the final `Vimage`, the pipeline's `%Format{}` op, and a `meta` map (from the source resolver) and returns `{:ok, body, content_type}` or `{:error, reason}`. The `body` is one of:

* `{:stream, Enumerable.t()}` — the encoder's preferred shape. Backed by `Image.stream!/2` (which wraps `Vix.Vips.Image.write_to_stream/2`) so libvips emits the encoded bytes chunk-by-chunk and `Image.Plug` pipes them through `Plug.Conn.send_chunked/2` + `Plug.Conn.chunk/2` straight to the client. No full encode is materialised in BEAM memory.

* `{:bytes, iodata()}` — fallback used when the response *must* be buffered to compute `Content-Length` (e.g. for HEAD requests, or when the host has explicitly disabled chunked transfer). Same encoder code path; just collects the stream into iodata before returning.

The `format=json` endpoint is always `{:bytes, iodata}` — its body is small and fully known up-front.

Format mapping:

| `Format.type` | `Image.write/3` suffix/options | `content_type` |
| --- | --- | --- |
| `:jpeg` | `:memory` + `suffix: ".jpg"`, `quality: q`, `strip_metadata: meta?` | `image/jpeg` |
| `:baseline_jpeg` | as `:jpeg` plus `interlace: false` (and `quality: q`); we set `progressive: false` explicitly | `image/jpeg` |
| `:webp` | `suffix: ".webp"`, `quality: q`, `effort:`, `min_size:` | `image/webp` |
| `:avif` | `suffix: ".avif"`, `quality: q`, `effort:` — soft fallback: if libvips lacks AVIF write support, encode as WebP and emit `Content-Type: image/webp` plus `X-Image-Server-Format-Fallback: avif->webp`. Detected once at app startup via a probe; warning logged then. README documents the requirement (libvips built with `libheif` + an AV1 encoder). | `image/avif` (or `image/webp` if fallback) |
| `:png` | `suffix: ".png"`, `compression: c` | `image/png` |
| `:json` | bypass libvips encode; build the documented JSON shape (width, height, format, bytes, etc.) via `:json.encode/1` | `application/json` |
| `:auto` | pick from `Accept` header: `image/avif` if accepted, else `image/webp` if accepted, else fall back to source content_type. Defaults to JPEG if the source format isn't a sensible terminal format | depends |

Metadata policy applied at encode time:

* `:keep` → write with metadata intact.

* `:copyright` → strip everything except the IPTC copyright field. Implemented by reading the field from the input image, stripping all metadata via `Image.write/3`'s `strip_metadata: true`, then writing the field back. (If `Image` doesn't already expose this convenience we add a small helper module rather than reaching into Vix from the encoder.)

* `:none` → `strip_metadata: true`.

`anim?: false` collapses an animated input to a single frame before encoding (uses `Image.extract_pages/1` + take first; or `Image.open/2` with `pages: 1`).

The plug then writes the response:

* `Content-Type: <content_type>`

* `Content-Length: <byte_size(iodata |> IO.iodata_to_binary())>` (we resolve to a binary for `Content-Length`; large outputs use `Plug.Conn.send_chunked/2` instead — threshold configurable, default 1 MiB).

* `Vary: Accept` (always, since `format=auto` is content-negotiated) plus `Vary: Save-Data` only if `slow-connection-quality` was set on the request.

* `ETag: "..."` and `Cache-Control: ...` per §15.

* `X-Image-Server-Variant: <name>` when the request resolved a variant — useful for log correlation.

## 13. Variant store

A variant is a stored, named `%Pipeline{}` plus a small bag of metadata. Variants are not bound to a particular source — they are reusable templates that any URL can name.

```elixir
defmodule Image.Plug.Variant do
  defstruct [:name, :pipeline, :metadata, :never_require_signed_urls?, :inserted_at, :updated_at]
end

defmodule Image.Plug.VariantStore do
  alias Image.Plug.Variant

  @callback get(name :: String.t(), options :: keyword()) ::
              {:ok, Variant.t()} | {:error, :not_found}

  @callback put(Variant.t(), options :: keyword()) ::
              {:ok, Variant.t()} | {:error, term()}

  @callback delete(name :: String.t(), options :: keyword()) ::
              :ok | {:error, :not_found}

  @callback list(options :: keyword()) :: {:ok, [Variant.t()]}
end
```

Default implementation: **`Image.Plug.VariantStore.ETS`**.

* A named `:protected` ETS table owned by a `GenServer` (`Image.Plug.VariantStore.ETS.Server`).

* Reads go straight to ETS (no GenServer call).

* Writes go through the GenServer to serialise puts and to fire telemetry.

* Seeded at startup from a `:seed_variants` config key (a keyword list of `{name, pipeline_or_options_string}` pairs). Strings are parsed via the configured provider so seeding can be expressed as `{"thumbnail", "width=200,height=200,fit=cover"}`.

* Always seeds a `"public"` variant matching Cloudflare's default behaviour (no transforms, format auto, metadata copyright) — required because the hosted URL form treats an absent `<tail>` as `public`.

Optional v0.2 backends:

* **`Image.Plug.VariantStore.File`** — JSON-on-disk via `:json.encode/1` / `:json.decode/1`. Good for static deployments.

* **`Image.Plug.VariantStore.Ecto`** — sketched only; left for hosts that want DB persistence.

The store is intentionally tiny. Authorization, audit, and multi-tenancy are out of scope — the host wraps the public CRUD surface in their own admin UI/auth as needed.

The CRUD surface is exposed as a public Elixir API (`Image.Plug.put_variant/2`, etc.).

### 13.1 HTTP admin plug

`Image.Plug.Admin` exposes the variant CRUD as JSON over HTTP. It mirrors the shape of Cloudflare's [`/accounts/{id}/images/v1/variants`](https://developers.cloudflare.com/api/operations/cloudflare-images-variants-create-a-variant) endpoints so existing tooling can target it with minimal change.

Routes (the host mounts this plug under whatever prefix they choose):

| Method | Path | Action |
| --- | --- | --- |
| `GET`    | `/`             | List variants → `{"result": [...]}` |
| `GET`    | `/:name`        | Get one variant; 404 if absent |
| `POST`   | `/`             | Create variant; 409 if name exists |
| `PUT`    | `/:name`        | Upsert variant |
| `PATCH`  | `/:name`        | Partial update (merge into existing) |
| `DELETE` | `/:name`        | Delete; 404 if absent |

Request bodies use the canonical pipeline JSON (see §13.2 below). Authn/authz is **not** built in — the host wraps the plug in their own auth pipeline. JSON is decoded/encoded via `:json` per the global standards.

### 13.2 Variant JSON shape

The on-the-wire JSON for a variant is:

```json
{
  "name": "thumbnail",
  "options": "width=200,height=200,fit=cover,format=webp",
  "metadata": {"description": "card thumbnail"},
  "never_require_signed_urls": false
}
```

`options` is a Cloudflare-style options string parsed by the configured provider — the same grammar the request URL uses. This keeps the admin API provider-aware without requiring callers to learn an IR-specific JSON schema. (We may add a structured `pipeline` key in a future version for non-Cloudflare providers; in v0.1 the options-string form is the only documented surface.)

The store internally serialises `%Variant{}` with the parsed `%Pipeline{}` plus a copy of the original options string for round-tripping.

## 14. Top-level plug and request lifecycle

`Image.Plug` is a standard `Plug` (`init/1`, `call/2`). `init/1` validates and freezes the configuration into an opaque `%Image.Plug.Options{}` struct so per-request work is just struct field reads.

`init/1` keys:

* `:provider` — `{module, opts}`. Required. e.g. `{Image.Plug.Provider.Cloudflare, mount: "/img", hosted_account_hash: "abc123"}`.

* `:source_resolver` — `{module, opts}`. Required.

* `:variant_store` — `{module, opts}`. Defaults to `{Image.Plug.VariantStore.ETS, []}`.

* `:cache` — `{module, opts}`. Defaults to `{Image.Plug.Cache.Default, []}`.

* `:on_error` — `:auto | :render_error_image | :fallback_to_source | :raise | {:status, integer()}`. Default `:auto`, which picks `:render_error_image` in `:dev` and `:fallback_to_source` in `:prod` based on `Application.get_env(:image_plug, :env, Mix.env())`. See §15.

* `:max_pixels` — soft upper bound on output pixel count (libvips will happily allocate huge buffers; we refuse early). Default 25 MP.

* `:request_timeout` — total budget per request including source fetch + decode + transform + encode. Default 10 s.

* `:telemetry_prefix` — atom list, default `[:image_plug]`. Events emitted: `[:image_plug, :request, :start | :stop | :exception]` with `%{provider, variant, source_kind, op_count, duration_native}` measurements/metadata.

`call/2` is a `with`-chain (no `try/rescue` — errors are tagged tuples per the global standards):

```elixir
def call(conn, %Options{} = options) do
  with {:ok, parsed}            <- options.provider.parse(conn, options.provider_opts),
       {:ok, pipeline, source}  <- resolve(parsed, options),
       {:ok, normalised}        <- Pipeline.Normaliser.normalise(pipeline),
       :ok                      <- guard_max_pixels(normalised, options.max_pixels),
       {:ok, image, meta}       <- options.source_resolver.load(source, options.source_resolver_opts),
       {:ok, transformed}       <- Pipeline.Interpreter.execute(normalised, image),
       {:ok, body, ctype}       <- Pipeline.Encoder.encode(transformed, normalised.output, meta) do
    conn
    |> put_cache_headers(meta, normalised, options)
    |> maybe_send_304()
    |> put_resp_content_type(ctype)
    |> send_resp(200, body)
  else
    {:error, %Error{} = error} ->
      Image.Plug.ErrorHandler.respond(conn, error, options)
  end
end
```

`resolve/2` handles three cases that come back from the provider:

1. `{:pipeline, p, source}` → return `{:ok, p, source}`.

2. `{:variant, name, overrides, source}` → look up the variant, merge overrides on top, return `{:ok, merged, source}`. Unknown variant → `{:error, %Error{tag: :variant_not_found, name: name}}`.

3. `{:passthrough, source}` → produce a `%Pipeline{ops: []}` (interpreter is a no-op, encoder pipes the source through).

The plug supports both `Plug.Router` mounting (`forward "/img", to: Image.Plug, init_opts: [...]`) and Phoenix endpoint mounting. Nothing in the plug talks to Phoenix-only APIs.

## 15. Caching, ETag, and `onerror`

ETag construction (strong validator):

```
etag = Base.url_encode64(
  :crypto.hash(:sha256,
    [meta.etag_seed, "|", Pipeline.fingerprint(normalised_pipeline), "|", chosen_format]
  ),
  padding: false
)
```

`Pipeline.fingerprint/1` walks the normalised op list and produces a stable binary (sorted keys per op, atoms inspected as strings). Because normalisation runs first, two URLs that differ only in option order produce the same ETag.

Cache-Control:

* If the source resolver's `meta` includes a `cache_control` directive (e.g. proxied from upstream), use it.

* Otherwise emit `public, max-age=3600, stale-while-revalidate=86400` by default. Configurable via the cache module.

* Add `immutable` only when the request resolved a variant *and* the source `etag_seed` is content-addressed (the host can opt in by setting `meta.immutable?: true`).

`Vary`: always include `Accept` (we negotiate `format=auto`); add `Save-Data` only when `slow-connection-quality` is in the request.

Conditional GET: if the inbound request has `If-None-Match` matching the computed ETag, return 304 with no body. We compute the ETag *before* running the interpreter (it's deterministic from the pipeline + source seed), so the 304 path skips libvips entirely.

`on_error` semantics:

* `:auto` (default) — selects `:render_error_image` when running under `:dev` and `:fallback_to_source` when running under `:prod`. The selection key is `Application.get_env(:image_plug, :env, Mix.env())` so releases (where `Mix.env/0` returns `:prod`) behave correctly without configuration.

* `:render_error_image` — generate a placeholder PNG at the requested target dimensions (or 400×300 when no target was given) with a high-contrast background, the error tag as a heading, and the human-readable message as a caption. Built via `Image.new/3` + `Image.Text.text/2` + `Image.compose/3`; encoded as PNG to keep dependencies minimal. Returns HTTP 200 so the broken image still renders in browsers and the developer sees what went wrong inline. Adds `X-Image-Server-Error: <tag>` and `Cache-Control: no-store` so the placeholder is never cached.

* `:fallback_to_source` — on any pipeline error after the source loaded successfully, stream the original source bytes with its original content-type, log the failure at `:error` level via `Logger.error/2` with a structured payload (`%{tag, message, request_path, source_kind}`), and add `X-Image-Server-Error: <tag>` and `Cache-Control: no-store`. Returns HTTP 200. If the source itself failed to load, this mode falls through to `{:status, code}` because there is nothing to stream back.

* `:raise` — let the error propagate. Useful in tests.

* `{:status, code}` — respond with the given status code and a small text body describing the error tag.

Error → status mapping (used by `:status` mode and as the default for non-source errors):

| Error tag | Status |
| --- | --- |
| `:unknown_option`, `:invalid_option`, `:malformed_url` | 400 |
| `:variant_not_found`, `:source_not_found` | 404 |
| `:unsupported_source_format`, `:unsupported_output_format` | 415 |
| `:source_too_large`, `:output_too_large` | 413 |
| `:request_timeout` | 504 |
| `:source_fetch_error` | 502 |
| anything else | 500 |

## 16. Configuration surface

A complete example mounting under a Phoenix endpoint:

```elixir
# config/config.exs
config :my_app, MyAppWeb.Endpoint,
  # ...
  http: [...]

# lib/my_app_web/endpoint.ex
plug Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare,
             mount: "/img",
             hosted_account_hash: "abc123",
             strict?: true},
  source_resolver: {Image.Plug.SourceResolver.Composite,
                    file:   [root: "priv/static/uploads"],
                    http:   [allowed_hosts: ["assets.example.com"], max_body_size: 20_000_000],
                    hosted: [table: :my_app_assets]},
  variant_store: {Image.Plug.VariantStore.ETS,
                  seed_variants: [
                    {"thumbnail", "width=200,height=200,fit=cover,format=webp"},
                    {"hero",      "width=1600,format=auto,quality=82"}
                  ]},
  cache: {Image.Plug.Cache.Default, max_age: 86_400},
  on_error: :fallback_to_source,
  max_pixels: 25_000_000,
  request_timeout: 10_000
```

Or as a standalone `Plug.Router`:

```elixir
defmodule MyImagePlug do
  use Plug.Router
  plug :match
  plug :dispatch
  forward "/img", to: Image.Plug, init_opts: [...]
end
```

The same `init_opts` keyword list works in both. Hosts that need per-environment differences keep the keyword in `Application.get_env/3` and pass it through.

## 17. Test plan

Test fixtures live under `test/fixtures/images/`. We commit a small set: a JPEG with EXIF, a PNG with alpha, an animated WebP, an SVG, and one HEIC if the CI image has libheif.

Per-module unit tests:

* **`Provider.Cloudflare.URL`** — table-driven tests covering: `/cdn-cgi/image/<options>/<source>` with absolute path, with `https://` source, with `http://` source, missing options, empty options; `imagedelivery.net`-style with variant tail, with options tail, with empty tail, with bogus account; `mount` prefix stripping.

* **`Provider.Cloudflare.Options`** — every option key in §9.2, including alias forms (`w`/`width`, etc.), boundary values (`quality=0`, `quality=101`, `dpr=3`), invalid values (`fit=bogus`, `gravity=99x99`), unknown keys with `strict?: true` vs `false`, multiple `draw=` entries → multiple layers.

* **`Pipeline.Normaliser`** — reordering produces the same fingerprint regardless of input order; no-op folding (`brightness=1` is removed); `%Adjust{}` consolidation; cardinality validation.

* **`Pipeline.Interpreter`** — for each op kind, run against a fixture image and assert the output dimensions / pixel-sample colour / format. The pixel assertions are loose tolerances — we're not testing libvips, just that we called the right call with the right args.

* **`Pipeline.Encoder`** — round-trip JPEG/WebP/AVIF/PNG; metadata stripping by policy; `format: :auto` content negotiation given various `Accept` headers; `format: :json` returns the documented JSON shape.

* **`VariantStore.ETS`** — get/put/delete/list, seeding from config, `public` is always present, telemetry events fire.

* **`SourceResolver.File`** — path traversal rejection, mtime → `last_modified`, missing file → `:source_not_found`.

* **`SourceResolver.HTTP`** — uses `Req.Test.stub/2` (or `Bypass`) to assert allow-list enforcement, max-body-size enforcement, ETag passthrough.

Integration tests via `Plug.Test`:

* Round-trip a request from URL to bytes for each Cloudflare URL form.

* Variant resolution: `/abc/img-id/thumbnail` returns the same bytes as `/cdn-cgi/image/<seeded-options>/img-id`.

* `If-None-Match` returns 304 with no body; ETag stable across requests.

* `format=auto` swaps based on `Accept` header.

* `onerror=redirect` style: pipeline error after source loaded streams the original.

Property tests (StreamData):

* For any random subset of supported options, `parse → normalise → fingerprint` is deterministic.

* `normalise` is idempotent: `normalise(normalise(p)) == normalise(p)`.

Definition-of-done gate (per global standards): every PR must pass `mix compile --warnings-as-errors`, `mix test`, `mix dialyzer`, and `MIX_ENV=release mix docs` cleanly on Elixir 1.20.0-rc.4-otp-28.

## 18. Phased rollout

Each milestone is independently reviewable and shippable.

**M1 — skeleton (no transforms yet).** `mix.exs` updated, supervisor, `%Pipeline{}` and op structs defined, behaviours for `Provider`, `SourceResolver`, `VariantStore` defined with no implementations yet. `Image.Plug` exists and returns 501 for everything. Tests cover the type definitions only. Definition-of-done gate green.

**M2 — file source + minimal Cloudflare options.** `SourceResolver.File` lands. `Provider.Cloudflare.URL` recognises `/cdn-cgi/image/<options>/<path>` only. `Provider.Cloudflare.Options` parses `width`, `height`, `fit`, `quality`, `format`. Interpreter handles `%Resize{}`, `%Format{}`. Encoder handles JPEG, PNG, WebP. End-to-end `Plug.Test` round-trip green. No variants yet, no ETag yet.

**M3 — full Cloudflare URL surface.** Hosted URL form lands. All §9.2 options parse and reach the interpreter (segment/zoom may stay placeholders). `%Adjust{}`, `%Sharpen{}`, `%Blur{}`, `%Background{}`, `%Trim{}`, `%Flip{}`, `%Rotate{}`, `%Border{}` interpreters land. AVIF and `format=auto` content negotiation land. `format=json` lands.

**M4 — variants.** `%Variant{}` struct, `VariantStore` behaviour, `VariantStore.ETS` impl, public CRUD API on `Image.Plug`. Hosted URL form resolves variants. `public` always seeded. Override merging (per-request options on top of a variant) works. README documents variant lifecycle.

**M5 — overlays + HTTP source.** `%Draw{}` interpreter (composite a resolved overlay onto the base image). `SourceResolver.HTTP` lands with allow-list and body-size limits. End-to-end test fetches an overlay from a stubbed remote.

**M6 — caching + telemetry + docs.** ETag computation, conditional GET 304 handling, Cache-Control header policy, `Vary` headers, `:fallback_to_source` `on_error`, telemetry events, README + guide pages. First Hex release candidate.

Each milestone ends with: green definition-of-done gate, an entry in CHANGELOG.md (Keep-a-Changelog format, 2-line max per entry), and a one-line suggested commit message in the PR description.

## 19. Resolved decisions

Answers from review:

1. **Module namespace** — `Image.Plug.*` (lives under the `Image` umbrella). All module references in this plan have been updated.

2. **Library vs. app** — library, consumable from a host Bandit/Phoenix app. `mix.exs` declares `elixir: "~> 1.17"`. Develop/CI on 1.20.0-rc.4-otp-28 per global standards.

3. **`image_plug` overlap** — `image_plug` is dead and will be deleted. No naming concern.

4. **Variant CRUD** — ship an HTTP admin plug in v0.1 (see §13.1 below).

5. **Drawing/overlays** — ship in v0.1, native. Use SVG overlays wherever possible (compose via `Image.from_svg/2` + `Image.compose/3`). Bitmap overlays still supported for `draw=url(...)` pointing at raster sources.

6. **AVIF** — soft fallback. If libvips lacks AVIF write support, log a warning at startup and fall back to WebP for `format=avif` requests. Documented prominently in the README.

7. **Source pass-through** — accepted. Provider returns `:passthrough` when it can prove the URL has no transformative ops; the plug streams the source unchanged.

8. **Per-derivative cache** — out of scope for v0.1.

9. **Telemetry** — per-request only (start/stop/exception). No per-op spans.

10. **`on_error` default** — fail softly. In `:dev`, render an error placeholder image at the requested target dimensions with the error message as a caption. In `:prod`, stream the original source bytes and log the failure at `:error`. The `on_error` config value defaults to `:auto`, which selects between these based on `Mix.env()` (or, in releases, on `:image_plug, :env` config); explicit `:render_error_image | :fallback_to_source | :raise | {:status, code}` overrides remain available.

These answers close §19. The downstream sections of this plan (§§13, 14, 15) have been amended to match.

_(Original questions removed; see resolved decisions above.)_

