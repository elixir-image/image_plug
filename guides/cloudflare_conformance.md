# Cloudflare Images conformance

This guide documents `image_plug`'s conformance to the [Cloudflare Images URL grammar](https://developers.cloudflare.com/images/transform-images/transform-via-url/) — what we implement, where we differ, and what we deliberately don't ship.

The reference is [Cloudflare's published URL spec](https://developers.cloudflare.com/images/transform-images/transform-via-url/). When this guide and Cloudflare's documentation disagree, treat Cloudflare's docs as the contract and file an issue against `image_plug`.

## URL forms

| Form | Cloudflare | `image_plug` | Notes |
| --- | --- | --- | --- |
| `/cdn-cgi/image/<options>/<source>` (path source) | ✅ | ✅ | Full support. |
| `/cdn-cgi/image/<options>/<https-source>` (URL source) | ✅ | ✅ | Inner URL must be percent-encoded so the path-split survives intermediaries. |
| `/<account_hash>/<image-id>/<variant-or-options>` (hosted) | ✅ | ✅ | Resolves variants against the configured `Image.Plug.VariantStore`. The implicit `"public"` variant is always seeded. |
| `/<account_hash>/<image-id>/<variant>?sig=...&exp=...` (signed URLs) | ✅ | ✅ | Same parameter names (`sig`, `exp`), same algorithm (HMAC-SHA256), same canonical-string rule for the typical signed-URL case. URL format is interchangeable with Cloudflare's hosted Images service. The HMAC value differs only because the secret is deployment-specific. Configure via `Image.Plug.Signing` and the plug's `:signing` option. |
| Workers binding (`fetch(request, { cf: { image: ... } })`) | ✅ | n/a | This is a JS API on Cloudflare's edge, not a URL form. `image_plug` is server-side Elixir; the Workers API has no analogue here. |

## Provider configuration

Both URL forms come from the same provider. Configure via:

```elixir
plug Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare,
             mount: "/img",
             hosted_account_hash: "abc123",
             strict?: true,
             variants_enabled?: true},
  source_resolver: ...
```

* `:hosted_account_hash` — when set, the hosted form is recognised. When `nil` (default), only `/cdn-cgi/image/...` is.

* `:variants_enabled?` — `false` disables variant lookup; hosted-form requests with a variant tail return `:variant_not_found`.

* `:strict?` — `true` (default) rejects unknown option keys with `:unknown_option`; `false` logs and ignores them.

## Option-key conformance

Every key Cloudflare documents in [the URL options reference](https://developers.cloudflare.com/images/transform-images/transform-via-url/). ✅ = full conformance. ⚠️ = partial / behavioural difference. ❌ = not implemented.

### Resize / sizing

| Key (alias) | Status | Notes |
| --- | --- | --- |
| `width` (`w`) | ✅ | Positive integer or `auto`. |
| `height` (`h`) | ✅ | Positive integer. |
| `fit` | ✅ | `contain`, `cover`, `crop`, `pad`, `scale-down`, `squeeze` — every documented value. |
| `gravity` (`g`) | ✅ | Named (`auto`/`face`/compass directions) and normalised `XxY` form. |
| `dpr` | ✅ | Multiplies output dimensions. Cloudflare documents 1..2; we accept up to 3. |
| `zoom` / `face-zoom` | ⚠️ | Parsed and stored on the IR; the interpreter does not yet act on it. Requests succeed; the option is silently a no-op. |

### Output / format

| Key (alias) | Status | Notes |
| --- | --- | --- |
| `quality` (`q`) | ✅ | `1..100` or named (`high`, `medium-high`, `medium-low`, `low`). |
| `format` (`f`) | ✅ | `auto`, `avif`, `webp`, `jpeg`, `baseline-jpeg`, `json`, plus `png` (we add this; Cloudflare emits PNG only via source-format pass-through). |
| `metadata` | ⚠️ | Parsed; M2 currently treats `:copyright` the same as `:none` (strips everything). Selective copyright preservation is a pending follow-up. |
| `anim` | ⚠️ | Parsed and stored on the IR; encoder does not yet act on it. Animated WebP/GIF inputs always emit a single frame in v0.1. |
| `compression` | ⚠️ | `fast` is parsed and stored; encoder does not yet wire it through to libvips' speed knobs. |
| `slow-connection-quality` (`scq`) | ⚠️ | Parsed and stored; we do not yet inspect the `Save-Data` request header to choose between `quality` and `scq_quality`. |

### Effects

| Key | Status | Notes |
| --- | --- | --- |
| `background` | ✅ | Hex (`#rgb`/`#rrggbb`/`#rrggbbaa`), CSS name, `rgb()` / `rgba()`. Forwarded verbatim to `Image.flatten/2`. |
| `blur` | ✅ | `0..250` mapped to a libvips Gaussian sigma via `sigma = N / 2` (matches the Sharp project's mapping). Out-of-range values clamp. |
| `sharpen` | ✅ | `0..10` mapped to a libvips sigma. |
| `brightness` | ✅ | Multiplier; 1.0 is a no-op. |
| `contrast` | ✅ | Multiplier. |
| `gamma` | ✅ | Multiplier. Routed via `Vix.Vips.Operation.gamma/2` since the `Image` library doesn't expose a top-level helper. |
| `saturation` | ✅ | Multiplier. |

### Geometry

| Key | Status | Notes |
| --- | --- | --- |
| `rotate` | ⚠️ | Cloudflare documents `90`, `180`, `270`. We accept any multiple of 90 (and reject the rest), so `360` works while Cloudflare may reject it. |
| `flip` | ✅ | `h`, `v`, `hv`. |
| `trim` | ✅ | `border` (auto-trim) and explicit `top;right;bottom;left`. |
| `border` | ✅ | Uniform `color=#hex;width=N` and per-side `color=#hex;top=N;right=N;bottom=N;left=N`. |

### Drawing / overlays

| Key | Status | Notes |
| --- | --- | --- |
| `draw` | ⚠️ | Cloudflare's docs only define `draw` for the Workers binding (a JSON array). We invent a URL grammar of the form `draw=url(<absolute-url>);width=N;height=N;fit=...;gravity=...;opacity=0.5;repeat=true|x|y;top=N;right=N;bottom=N;left=N;background=#hex;rotate=90`. Multiple `draw=` entries become multiple layers in declaration order. The inner `url(...)` and `;` separators must be percent-encoded so the path-split survives. The interpreter prefers SVG composition for `.svg` sources (scale-clean); bitmap sources are decoded and composited with the configured opacity and position. |

### Misc

| Key | Status | Notes |
| --- | --- | --- |
| `segment` | ⚠️ | `foreground` is parsed and stored on the IR. The interpreter is currently a no-op; subject segmentation lands in a future milestone. |
| `onerror` | ⚠️ | `redirect` is parsed and maps to `pipeline.on_error = :fallback_to_source`. We do not yet honour the URL-level value over the plug-level `:on_error` config — the plug config wins. |

## Behavioural differences

These are intentional choices where `image_plug` does something Cloudflare does not (or vice versa).

### Format negotiation for `format=auto`

Cloudflare picks AVIF → WebP → original-format based on the `Accept` header and the source's content-type. We do the same, gated by `Image.Plug.Capabilities.avif_write?/0` — if libvips lacks AVIF write support at boot, the AVIF tier is skipped and `format=avif` (whether requested explicitly or via `auto`) is served as WebP, with `x-image-plug-format-fallback: avif->webp` on the response. Cloudflare's edge always has AVIF; ours depends on the build. Document this loudly to users.

### Output format negotiation: `image/*` and `*/*` in `Accept`

Per the HTTP spec, `image/*` matches every `image/<subtype>`. We honour that — if `image/*` is present and `Image.Plug.Capabilities.avif_write?/0` is true, `format=auto` returns AVIF. Cloudflare's behaviour with `image/*` alone is not documented; this is an interpretation, not a contract.

### Option-cardinality

Cloudflare's docs are silent on what happens when an option key appears twice (`width=200,width=400`). We treat duplicates as last-wins through the parser, then the normaliser enforces "at most one" cardinality per op kind and raises `:invalid_option` if multiple op-emitting keys collide after parsing (e.g. two `width=` entries that produce two `Resize` ops would fail normalisation). In practice the parser already de-duplicates inside one Resize op so this only matters for the few keys that emit a fresh op each time. Behaviour is consistent and predictable; it may differ from Cloudflare's edge.

### ETag derivation

Cloudflare's URLs are content-addressed by their CDN; ours derive a strong ETag from `meta.etag_seed` (provided by the source resolver) plus the normalised pipeline's fingerprint plus the chosen output format. Two URLs that differ only in option order produce the same ETag. If you mirror Cloudflare's URLs through `image_plug` and want a single consistent cache key across both deployments, you'll need to either canonicalise URLs upstream or accept different ETags.

### `<picture>` markup is the client's responsibility

Cloudflare's documented URL grammar is consumed by client markup the developer writes by hand or via a JS helper. We do the same: `image_plug` serves bytes, and the [`image_components`](https://hex.pm/packages/image_components) sister package emits `<.image>` and `<.picture>` markup using the same URL grammar.

## Conformance summary

| Category | Conformance | Notes |
| --- | --- | --- |
| URL forms | High | Both `/cdn-cgi/image/...` and hosted forms; signed URLs deferred. |
| Sizing options (`width`/`height`/`fit`/`gravity`/`dpr`) | High | `zoom`/`face-zoom` is a parsed-but-no-op stub. |
| Output format negotiation (`format=auto`, `Accept`) | High | AVIF gated on libvips capability; documented soft fallback. |
| Effects (`background`/`blur`/`sharpen`/colour adjustments) | Full | Every documented value handled. |
| Geometry (`rotate`/`flip`/`trim`/`border`) | Full | `rotate` is slightly more permissive than Cloudflare. |
| Drawing/overlays (`draw=`) | Partial | URL grammar invented (Cloudflare doesn't define one); SVG-preferred composition; opacity/position implemented; `repeat=true|x|y` not yet executed. |
| Metadata (`metadata=copyright`) | Partial | Treats `:copyright` as `:none` for now. |
| Animation (`anim=false`) | Stub | Parsed; encoder doesn't yet collapse animated inputs. |
| Subject segmentation (`segment=foreground`) | Stub | Parsed; interpreter is a no-op. |
| URL-level `onerror=redirect` | Partial | Parsed; plug-level `:on_error` config wins until the request-level override lands. |
| Signed URLs | Full | Same parameter names (`sig`, `exp`), algorithm (HMAC-SHA256), and canonical string as Cloudflare's hosted Images. URL format interchangeable; HMAC value differs because secrets do. |

## Reporting gaps

Open an issue at the project's GitHub. Include the request URL, the expected behaviour per Cloudflare's docs (with a link), and the actual response.

