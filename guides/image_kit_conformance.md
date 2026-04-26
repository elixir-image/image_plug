# ImageKit conformance

This guide documents `image_plug`'s conformance to the [ImageKit URL grammar](https://imagekit.io/docs/transformations) — what we implement, where we differ, and what we deliberately don't ship.

The reference is [ImageKit's published transformation docs](https://imagekit.io/docs/transformations). When this guide and ImageKit's docs disagree, treat ImageKit's docs as the contract and file an issue against `image_plug`.

## URL forms

| Form | ImageKit | `image_plug` | Notes |
| --- | --- | --- | --- |
| `<host>/<endpoint>/tr:<transforms>/<source>` (path-prefix) | ✅ | ✅ | The default form. Source path resolved by the configured `Image.Plug.SourceResolver`. |
| `<host>/<endpoint>/<source>?tr=<transforms>` (query-string) | ✅ | ✅ | Both forms recognised on inbound. The component-side adapter emits the path-prefix form. |
| `<host>/<endpoint>/<source>` (no transforms) | ✅ | ✅ | Passthrough — the source is streamed unchanged. |
| Chained transforms (`tr:w-200,h-100:rt-90`) | ✅ | ⚠️ | Recognised; the v0.1 IR doesn't model multi-stage pipelines, so all stages flatten to one comma-joined option set. Order-dependent recipes collapse to last-write-wins. |
| Signed URLs (`?ik-s=<hex>` + `?ik-t=<unix>`) | ✅ | ✅ | HMAC-SHA1 over the path-and-query (excluding `ik-s`). Wire-format-compatible with ImageKit's hosted signed URLs. |
| Remote-image endpoint (absolute `https://...` source) | ✅ | ✅ | Recognised; resolved by `SourceResolver.HTTP` when configured. |
| Named transformations (`tr:n-<name>` or `t-<name>`) | ✅ | ❌ | Server-side aliases; not modelled by the IR. Returns `:unsupported_option`. |

## Provider configuration

```elixir
plug Image.Plug,
  provider: {Image.Plug.Provider.ImageKit,
             mount: "",
             endpoint: "your_imagekit_id",
             strict?: true,
             signing: %{keys: [secret], required?: true}},
  source_resolver: ...
```

* `:mount` — path prefix to strip first. Defaults to `""` (root).

* `:endpoint` — additional path segment to strip after `:mount`. ImageKit URLs commonly include a per-account endpoint id (e.g. `/your_imagekit_id/`). Defaults to `""`.

* `:strict?` — `true` (default) rejects unknown ImageKit option keys with `:unknown_option`. `false` logs and ignores.

* `:signing` — `nil` or `%{keys: [...], required?: bool}`. Wire format matches ImageKit's hosted SHA-1 signed URLs.

## Option-key conformance

Every option ImageKit documents in [the transformation reference](https://imagekit.io/docs/transformations). ✅ = full conformance. ⚠️ = partial / behavioural difference. ❌ = not implemented.

### Sizing

| Key | Status | Notes |
| --- | --- | --- |
| `w-<n>` | ✅ | Positive integer. |
| `h-<n>` | ✅ | Positive integer. |
| `dpr-<n>` | ⚠️ | ImageKit accepts up to `auto`; we cap at 3. |
| `c-maintain_ratio` / `cm-maintain_ratio` | ✅ | Maps to `Resize{fit: :contain}`. |
| `c-force` / `cm-force` | ✅ | Maps to `Resize{fit: :squeeze}`. |
| `c-at_least` / `c-at_max` | ✅ | Maps to `Resize{fit: :scale_down}`. |
| `c-at_max_enlarge` | ⚠️ | Approximated as `:contain`; the upscaling-when-smaller behaviour is not implemented. |
| `c-extract` / `cm-extract` | ✅ | Maps to `Resize{fit: :crop}` (absolute-pixel crop). |
| `c-pad_extract` / `cm-pad_extract` | ✅ | Maps to `Resize{fit: :pad}`. |
| `c-pad_resize` / `cm-pad_resize` | ✅ | Maps to `Resize{fit: :pad}`. |
| `fo-<position>` | ✅ | `top`, `bottom`, `left`, `right`, `top_left`, etc. → compass gravities. |
| `fo-face` | ✅ | Face-aware crop. |
| `fo-auto` | ⚠️ | Maps to libvips' `:entropy` crop; ImageKit's content-aware crop is approximated. |
| `fo-custom` + `x-<n>` + `y-<n>` | ✅ | 0..1 normalised focal point. |

### Format / output

| Key | Status | Notes |
| --- | --- | --- |
| `q-<n>` | ✅ | 1..100. |
| `f-jpg` / `f-jpeg` / `f-png` / `f-webp` / `f-avif` | ✅ | |
| `f-auto` | ✅ | Same Accept-driven negotiation as the other providers. |
| `lo-true` (lossless) | ❌ | Returns `:unsupported_option`; the encoder doesn't wire a lossless flag through to libvips yet. |
| `pr-true` (progressive) | ❌ | Returns `:unsupported_option`; progressive JPEG is reachable via `f-pjpg`-style aliases but ImageKit's `pr-` flag isn't modelled. |
| `cp-<n>` (chroma subsampling) | ❌ | Returns `:unsupported_option`. |

### Effects

| Key | Status | Notes |
| --- | --- | --- |
| `bg-<hex>` | ✅ | Hex (with or without leading `#`). |
| `e-blur-<n>` | ✅ | 0..2000; mapped to libvips sigma via `sigma = N / 100`. |
| `e-sharpen-<n>` | ✅ | 0..100; `sigma = N / 10`. |
| `e-usm-<radius>-<sigma>-<amount>-<threshold>` | ⚠️ | Approximated by mapping the `<sigma>` component to libvips `Sharpen` sigma; the radius/amount/threshold tweaks are not modelled. |
| `e-grayscale` / `e-greyscale` | ✅ | Approximated as `Adjust{saturation: 0}`. |
| `e-contrast` | ⚠️ | ImageKit's auto-contrast toggle; we approximate as `Adjust{contrast: 1.1}` (a mild bump). Real visual difference on low-contrast inputs. |
| `e-shadow` | ❌ | Needs a drop-shadow helper in the Image library — returns `:unsupported_option`. |
| `e-gradient` | ❌ | Needs a gradient overlay helper — returns `:unsupported_option`. |
| `e-removedotbg` / `e-bgremove` / `e-changebg` / `e-edit` | ❌ | Third-party generative-AI calls; not implemented. |
| `e-retouch` / `e-upscale` | ❌ | Model-driven enhancement / super-resolution; not implemented. |

### Geometry

| Key | Status | Notes |
| --- | --- | --- |
| `rt-<n>` | ⚠️ | ImageKit accepts arbitrary integer plus `auto`; we accept multiples of 90 only. |
| `b-<W>_<color>` / `b-<W>-<color>` | ✅ | Uniform-width border. Per-side border not supported in ImageKit's grammar. |
| `r-<n>` / `r-max` (rounded corners) | ❌ | Not implemented in v0.1. |

### Overlays

| Key | Status | Notes |
| --- | --- | --- |
| `oi-<image-path>` | ⚠️ | Single-layer base form supported; the path is resolved through the configured `SourceResolver`. ImageKit's nested overlay syntax (`l-image,i-<path>,...,l-end`) is not implemented. |
| `ot-<text>` | ❌ | Text overlays not implemented in v0.1. |
| `obg-<color>` | ❌ | Overlay-background not implemented. |

### Misc

| Key | Status | Notes |
| --- | --- | --- |
| `ik-s` | ✅ | HMAC signature (handled by `Image.Plug.Provider.ImageKit.Signing`). |
| `ik-t` | ✅ | Used by signing; the verifier rejects after this unix-seconds timestamp. |
| `t-<name>` | ❌ | Named (server-side alias) transformations not modelled by the IR. Returns `:unsupported_option`. |
| `ar-<W>-<H>` (aspect-ratio shortcut) | ❌ | Not implemented in v0.1. |
| `z-<n>` (zoom) | ❌ | Not implemented in v0.1. |

## Behavioural differences

### Multi-stage chained transforms collapse to one stage

ImageKit lets you chain transforms with `:`: `tr:w-200,h-100:rt-90:e-blur-300`. The v0.1 IR doesn't model multi-pass pipelines — all options compose into one Resize op, one Adjust op, etc.

The provider flattens chained stages by joining them with `,` and processes them as a single set. For most useful transforms (resize + format + quality + a single effect) this is identical to ImageKit. Recipes that genuinely require ordering lose information: only the last write per op kind survives.

### Path-prefix vs query-string

ImageKit accepts both `tr:w-200/sample.jpg` and `sample.jpg?tr=w-200`. The provider recognises both — and even accepts a mix (`tr:w-200/sample.jpg?tr=q-80` produces the merged set `w-200,q-80`). The component-side adapter only emits the path-prefix form (the documented default). Mixing is permitted on inbound for compatibility with hand-rolled URLs.

### Canonical-string for signing

ImageKit's HMAC payload is the path-and-query of the request, with the `ik-s` parameter removed but the `ik-t` parameter retained. The hash is HMAC-SHA1 keyed by the secret, hex-encoded lowercase. We replicate this exactly. URLs signed by ImageKit's hosted service verify against an `image_plug` deployment with the same secret, and vice-versa.

### `e-contrast` is approximated

ImageKit's `e-contrast` is a single boolean toggle (auto-contrast on the input). The Image library doesn't expose a content-aware contrast knob, so we approximate as `Adjust{contrast: 1.1}` — a fixed mild bump. Visible on low-contrast inputs; close-enough on the rest.

## Conformance summary

| Category | Conformance | Notes |
| --- | --- | --- |
| URL forms | Full | Path-prefix + query-string + signed all wire-compatible; chained transforms flatten. |
| Sizing options (`w`/`h`/`c-`/`fo-`/`x`/`y`) | High | `c-at_max_enlarge` and `fo-auto` approximated. |
| Output format (`f-`, `q-`, `dpr-`) | High | `lo-`/`pr-`/`cp-` deferred. |
| Effects (`bg-`/`e-blur`/`e-sharpen`/`e-grayscale`/`e-contrast`/`e-usm`) | Medium | Common effects work; shadow / gradient / AI-driven calls deferred. |
| Geometry (`rt-`/`b-`) | Medium | `rt-` 90-multiples only; `r-` (rounded corners) not implemented. |
| Overlays (`oi-`) | Partial | Base layer form only. |
| Signed URLs | Full | Wire-format-compatible with ImageKit's hosted service. |

## Reporting gaps

Open an issue at the project's GitHub. Include the request URL, the expected behaviour per ImageKit's docs (with a link), and the actual response.
