# imgix conformance

This guide documents `image_plug`'s conformance to the [imgix URL grammar](https://docs.imgix.com/en/latest/apis/rendering) — what we implement, where we differ, and what we deliberately don't ship.

The reference is [imgix's published rendering API](https://docs.imgix.com/en/latest/apis/rendering). When this guide and imgix's docs disagree, treat imgix's docs as the contract and file an issue against `image_plug`.

## URL forms

| Form | imgix | `image_plug` | Notes |
| --- | --- | --- | --- |
| `<host>/<source-path>?<options>` (web folder) | ✅ | ✅ | Source path resolved by the configured `Image.Plug.SourceResolver`. |
| `<host>/<percent-encoded-https-url>?<options>` (web proxy) | ✅ | ✅ | Single percent-encoded path segment. Resolved by `SourceResolver.HTTP`. |
| Signed URLs (`?s=<hex>`) | ✅ | ✅ | HMAC-SHA256 over `secret <> path-and-query`. Wire-format-compatible with imgix's hosted signed URLs. |
| URL templating / placeholders | ✅ | ❌ | Out of scope; that's a publishing-time feature, not a request-time one. |

## Provider configuration

```elixir
plug Image.Plug,
  provider: {Image.Plug.Provider.Imgix,
             mount: "",
             strict?: true,
             signing: %{keys: [secret], required?: true}},
  source_resolver: ...
```

* `:mount` — path prefix to strip before treating the rest as the source. Defaults to `""` (root). Most imgix deployments live at the root of their (sub)domain.

* `:strict?` — `true` (default) rejects unknown imgix option keys with `:unknown_option`. `false` logs and ignores.

* `:signing` — `nil` or `%{keys: [...], required?: bool}`. Wire format matches imgix.

## Option-key conformance

Every option imgix documents in [the rendering reference](https://docs.imgix.com/en/latest/apis/rendering). ✅ = full conformance. ⚠️ = partial / behavioural difference. ❌ = not implemented.

### Sizing

| Key | Status | Notes |
| --- | --- | --- |
| `w` | ✅ | Positive integer. |
| `h` | ✅ | Positive integer. |
| `dpr` | ⚠️ | imgix accepts up to 5; we cap at 3 (matches what every browser actually requests). |
| `fit=clip` | ✅ | Maps to `Resize{fit: :contain}`. |
| `fit=clamp` | ⚠️ | Should extend edge pixels into the padded area; we currently treat as `:contain`. Real visual difference; landing in a follow-up. |
| `fit=crop` | ✅ | + `crop=` for position. |
| `fit=facearea` | ✅ | Maps to face-aware crop via gravity `:face`. |
| `fit=fill` | ✅ | Maps to `Resize{fit: :pad}`; combine with `bg=`. |
| `fit=fillmax` | ✅ | Two-step: resize down then pad. |
| `fit=max` | ✅ | Never upscale. |
| `fit=min` | ⚠️ | Approximated as `:scale_down`; imgix's `min` semantics are slightly different. |
| `fit=scale` | ✅ | Force exact dimensions. |
| `crop=top/bottom/left/right` | ✅ | Maps to compass gravities. |
| `crop=top,left` etc. | ✅ | Combined corner gravities. |
| `crop=faces` | ✅ | |
| `crop=entropy` / `edges` | ✅ | Both map to libvips' `:entropy` crop. |
| `crop=focalpoint` + `fp-x` + `fp-y` | ✅ | 0..1 normalised focal point. |

### Format / output

| Key | Status | Notes |
| --- | --- | --- |
| `q` | ✅ | 1..100. |
| `fm=jpg` / `jpeg` / `pjpg` / `png` / `webp` / `avif` | ✅ | `pjpg` maps to baseline JPEG. |
| `fm=jp2` | ❌ | We don't encode JPEG 2000. Returns `:invalid_option`. |
| `auto=format` | ✅ | Same Accept-driven negotiation as the Cloudflare provider. |
| `auto=compress` | ⚠️ | Sets `Format.compression = :fast` but the encoder doesn't yet wire it through to libvips' speed knobs. |
| `auto=enhance` | ❌ | Needs an `enhance/1` helper in the Image library — see this project's `TODO.md`. Returns `:unsupported_option`. |
| `auto=redeye` | ❌ | Returns `:unsupported_option`. |

### Effects

| Key | Status | Notes |
| --- | --- | --- |
| `bg` | ✅ | Hex (with or without leading `#`). |
| `blur` | ✅ | 0..2000; mapped to libvips sigma via `sigma = N / 100`. |
| `sharp` | ✅ | 0..100; `sigma = N / 10`. |
| `bri` / `con` / `sat` / `gam` | ✅ | -100..100 mapped to multiplier `1.0 + N/100`. |
| `sepia` | ❌ | Needs a `sepia/1` helper in the Image library — returns `:unsupported_option`. |
| `monochrome` | ❌ | Needs a `monochrome/2` helper in the Image library — returns `:unsupported_option`. |
| `px` (pixelate) | ❌ | Needs a `pixelate/2` helper in the Image library. |

### Geometry

| Key | Status | Notes |
| --- | --- | --- |
| `flip=h/v/hv` | ✅ | |
| `rot` | ⚠️ | imgix documents arbitrary integer; we accept multiples of 90 only (libvips constraint without expensive rotation). |
| `or` (EXIF orientation override) | ❌ | Needs `Image` to expose orientation control. Returns `:unsupported_option`. |
| `trim=auto` | ✅ | Maps to `Trim{mode: :border}`. |
| `trim=color` + `trimcolor` | ⚠️ | Recognised; the IR's `Trim` op accepts a colour but the interpreter ignores it (auto-detects instead). |
| `border=W,#hex` | ✅ | Uniform-width border. Per-side border not supported in imgix's grammar. |

### Overlays

| Key | Status | Notes |
| --- | --- | --- |
| `mark` (overlay URL) | ✅ | Resolved through the configured `SourceResolver`. If your deployment doesn't include `:url` resolution, `mark=https://...` errors with `:invalid_option`. |
| `mark-w` / `mark-h` | ⚠️ | Parsed but the v0.1 `Draw.Layer` IR uses a single resize-fit model rather than separate W/H; rounded approximation. |
| `mark-x` / `mark-y` | ✅ | Pixel offsets from the top-left. |
| `mark-fit` | ✅ | Same fit modes as the base image. |
| `mark-rot` | ✅ | Multiples of 90. |
| `mark-pad` | ❌ | Not implemented. |
| `markalign` (named position) | ⚠️ | `top`, `bottom`, `left`, `right` — combined into x/y offsets. `middle`/`center` only. |

### Misc

| Key | Status | Notes |
| --- | --- | --- |
| `cs` (colour space) | ❌ | Needs a `colorspace/2` helper in the Image library for mid-pipeline conversion. Returns `:unsupported_option`. |
| `expires` | ✅ | Used by signing; the verifier rejects after this unix-seconds timestamp. |
| `s` | ✅ | HMAC signature. |
| `ixlib` / `ixid` | ✅ | imgix client-identification keys. Recognised and silently ignored. |

## Behavioural differences

### Canonical-string for signing

Imgix's HMAC payload prepends the secret to the path-and-query: `payload = secret <> path <> "?" <> query`. The HMAC key is also the secret. We replicate this exactly. URLs signed by imgix's hosted service verify against an `image_plug` deployment with the same secret, and vice-versa. No wire-level translation needed.

### Multi-value `auto`

`auto=format,compress` is two effects in one parameter. The parser splits on `,` before per-effect dispatch. If any one effect is unsupported (`auto=enhance` for example) the whole parameter errors with `:unsupported_option` naming the offending sub-value.

### `crop=` requires `fit=crop` to take effect

imgix documents that `crop=` is only honoured when `fit=crop` (or `fit=facearea`) is set. The provider doesn't enforce this — `crop=top` without `fit=` parses cleanly and the gravity is recorded on the Resize op. If no resize happens (no `w`/`h`), the gravity is moot. Behaviour matches imgix's: silently ignored.

## Conformance summary

| Category | Conformance | Notes |
| --- | --- | --- |
| URL forms | Full | Web folder + web proxy + signed. |
| Sizing options (`w`/`h`/`fit`/`crop`/`fp-x`/`fp-y`) | High | `fit=clamp` and `fit=min` approximated. |
| Output format (`fm`, `auto=format`) | High | `auto=enhance` deferred. |
| Effects (`bg`/`blur`/`sharp`/colour adjusts) | High | `sepia`/`monochrome`/`px` deferred to `Image` upstream. |
| Geometry (`flip`/`rot`/`trim`/`border`) | High | `rot` 90-multiples only. |
| Overlays (`mark*`) | Partial | Common subset; `mark-pad`/`markalign=middle` deferred. |
| Colour-space (`cs`) | None | Deferred to `Image` upstream. |
| Signed URLs | Full | Wire-format-compatible with imgix's hosted service. |

## Reporting gaps

Open an issue at the project's GitHub. Include the request URL, the expected behaviour per imgix's docs (with a link), and the actual response.
