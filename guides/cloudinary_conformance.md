# Cloudinary conformance

This guide documents `image_plug`'s conformance to the [Cloudinary delivery URL grammar](https://cloudinary.com/documentation/transformation_reference) — what we implement, where we differ, and what we deliberately don't ship.

The reference is [Cloudinary's published transformation reference](https://cloudinary.com/documentation/transformation_reference). When this guide and Cloudinary's docs disagree, treat Cloudinary's docs as the contract and file an issue against `image_plug`.

## URL forms

| Form | Cloudinary | `image_plug` | Notes |
| --- | --- | --- | --- |
| `<host>/<account>/image/upload/<transforms>/<source>` (single stage) | ✅ | ✅ | The everyday delivery URL. Source resolved by the configured `Image.Plug.SourceResolver`. |
| `<host>/<account>/image/upload/<stage1>/<stage2>/<source>` (chained transforms) | ✅ | ⚠️ | Recognised; the v0.1 IR doesn't model multi-stage pipelines, so all stages flatten to one comma-joined option set. Order-dependent multi-stage recipes (sharpen → resize → sharpen) collapse to last-write-wins. |
| `<host>/<account>/image/fetch/<transforms>/<https-url>` (web proxy) | ✅ | ✅ | Cloudinary accepts the absolute URL either fully percent-encoded or in the natural form (split across path segments); both work. Source kind is `:url`. |
| `<host>/<account>/image/upload/s--<sig>--/<transforms>/<source>` (signed) | ✅ | ✅ | SHA-256 truncated to 32 url-safe-base64 characters. Wire-format-compatible with Cloudinary's hosted signed URLs. |
| Eager / named / responsive transformations (`t_<name>`) | ✅ | ❌ | Server-side aliases; not modelled by the IR. Returns `:unsupported_option`. |
| Conditional transformations (`if_...`) | ✅ | ❌ | Out of scope for v0.1. |
| Video / raw resource types | ✅ | ❌ | We're an image server. `<resource-type>` is parsed but only `image` is exercised. |

## Provider configuration

```elixir
plug Image.Plug,
  provider: {Image.Plug.Provider.Cloudinary,
             mount: "",
             account: "demo",
             strict?: true,
             signing: %{keys: [secret], required?: true}},
  source_resolver: ...
```

* `:mount` — path prefix to strip before treating the rest as a Cloudinary URL. Defaults to `""` (root).

* `:account` — when set, asserts the URL's account segment matches this value (rejects mismatches with `:malformed_url`). When `nil` (default), any account segment is accepted and reported through the recogniser.

* `:strict?` — `true` (default) rejects unknown Cloudinary option keys with `:unknown_option`. `false` logs and ignores.

* `:signing` — `nil` or `%{keys: [...], required?: bool}`. Wire format matches Cloudinary's hosted SHA-256 signed URLs (32 url-safe-base64 characters).

## Option-key conformance

Every option Cloudinary documents in [the transformation reference](https://cloudinary.com/documentation/transformation_reference). ✅ = full conformance. ⚠️ = partial / behavioural difference. ❌ = not implemented.

### Sizing

| Key | Status | Notes |
| --- | --- | --- |
| `w_<n>` | ✅ | Positive integer. |
| `h_<n>` | ✅ | Positive integer. |
| `dpr_<n>` | ⚠️ | Cloudinary accepts up to `auto`; we cap at 3. |
| `c_scale` | ✅ | Maps to `Resize{fit: :squeeze}` (force exact dims). |
| `c_fit` | ✅ | Maps to `Resize{fit: :contain}`. |
| `c_limit` | ✅ | Maps to `Resize{fit: :scale_down}`. |
| `c_mfit` | ⚠️ | Approximated as `:contain`; Cloudinary's `mfit` upscales when smaller. |
| `c_fill` / `c_lfill` | ✅ | Maps to `Resize{fit: :cover}`. |
| `c_crop` | ✅ | Maps to `Resize{fit: :crop}` (absolute-pixel crop). |
| `c_thumb` | ✅ | Maps to `Resize{fit: :cover}` (face-aware thumbnail when combined with `g_face`). |
| `c_pad` / `c_lpad` / `c_mpad` / `c_fill_pad` | ✅ | Maps to `Resize{fit: :pad}`. |
| `c_imagga_crop` / `c_imagga_scale` | ⚠️ | Approximated as `:cover` / `:squeeze`; the AI-driven crop selection is not implemented. |
| `g_<position>` | ✅ | `north`, `south`, `east`, `west`, `north_east`, etc. → compass gravities. |
| `g_face` / `g_faces` | ✅ | Face-aware crop. |
| `g_auto` / `g_auto:subject` / `g_auto:classic` | ⚠️ | All map to libvips' `:entropy` crop; the content-aware variants are approximated. |
| `g_xy_center` + `x_<n>` + `y_<n>` | ✅ | 0..1 normalised focal point. |

### Format / output

| Key | Status | Notes |
| --- | --- | --- |
| `q_<n>` | ✅ | 1..100. |
| `q_auto` / `q_auto:eco` / `q_auto:good` / `q_auto:best` | ⚠️ | All map to encoder default (85) plus `compression: :fast`. Cloudinary's content-aware quality model is not implemented; needs an enhance helper in the Image library — see TODO.md. |
| `f_jpg` / `f_jpe` / `f_jpeg` / `f_png` / `f_webp` / `f_avif` | ✅ | |
| `f_auto` | ✅ | Same Accept-driven negotiation as the other providers. |
| `f_jp2` | ❌ | We don't encode JPEG 2000. Returns `:invalid_option`. |
| `fl_force_strip` / `fl_progressive` / `fl_lossy` / `fl_preserve_transparency` | ⚠️ | Recognised and silently accepted; the encoder doesn't yet wire these flags through to libvips. |

### Effects

| Key | Status | Notes |
| --- | --- | --- |
| `b_rgb:<hex>` / `b_<color>` | ✅ | Hex (`rgb:RRGGBB[AA]`) or named colour. |
| `e_blur:<n>` | ✅ | 0..2000; mapped to libvips sigma via `sigma = N / 100`. |
| `e_sharpen:<n>` | ✅ | 0..100; `sigma = N / 10`. |
| `e_brightness:<n>` / `e_contrast:<n>` / `e_saturation:<n>` / `e_gamma:<n>` | ✅ | -100..100 mapped to multiplier `1.0 + N/100`. |
| `e_grayscale` / `e_greyscale` | ✅ | Approximated as `Adjust{saturation: 0}`. |
| `e_sepia` | ❌ | Needs a `sepia/1` helper in the Image library — returns `:unsupported_option`. |
| `e_vignette` | ❌ | Needs a vignette helper — returns `:unsupported_option`. |
| `e_pixelate` / `e_pixelate_faces` | ❌ | Needs a pixelate helper — returns `:unsupported_option`. |
| `e_cartoonify` | ❌ | Needs a posterize helper — returns `:unsupported_option`. |
| `e_replace_color:<to>[:<tolerance>[:<from>]]` | ✅ | Wraps `Image.replace_color/2`. Defaults: `<from>` = `:auto` (top-left 10×10 average), `<tolerance>` = 50. Colours accept hex (`ffffff`), `rgb:RRGGBB` form, and CSS names. |
| `e_fade` | ❌ | Needs a gradient overlay helper — returns `:unsupported_option`. |
| `e_improve` / `e_auto_brightness` / `e_auto_color` / `e_auto_contrast` | ❌ | Needs an enhance helper — returns `:unsupported_option`. |
| `e_redeye` | ❌ | Returns `:unsupported_option`. |

### Geometry

| Key | Status | Notes |
| --- | --- | --- |
| `a_<n>` | ⚠️ | Cloudinary accepts arbitrary integer; we accept multiples of 90 only (libvips constraint without expensive rotation). |
| `a_auto_right` / `a_auto_left` / `a_vflip` / `a_hflip` | ❌ | Compound rotation modes not implemented. |
| `bo_<W>px_solid_<color>` | ✅ | Uniform-width border. Per-side border not supported in Cloudinary's grammar. |
| `r_<n>` / `r_max` | ❌ | Rounded corners not implemented in v0.1. |
| `o_<n>` (opacity) | ❌ | Mid-pipeline opacity not implemented in v0.1. |

### Overlays

| Key | Status | Notes |
| --- | --- | --- |
| `l_<public-id>` | ⚠️ | Single-layer base form supported; the public-id is resolved through the configured `SourceResolver` as a path. Composite overlay positioning (`g_`/`x_`/`y_` per-overlay) is not implemented. |
| `l_text:<font>:<text>` | ❌ | Text overlays not implemented in v0.1. |
| `u_<public-id>` | ❌ | Underlays not implemented. |

### Misc

| Key | Status | Notes |
| --- | --- | --- |
| `cs_srgb` / `cs_tinysrgb` / `cs_cmyk` / `cs_no_cmyk` | ✅ | Wraps `Image.to_colorspace/2`. `cs_tinysrgb` and `cs_no_cmyk` both map to `:srgb` (Cloudinary's tinification is a product layer, not a libvips colorspace). |
| `cs_<other>` (Adobe RGB, custom ICC profiles) | ❌ | Needs a 3-arity `to_colorspace` (or `icc_transform`) helper in the Image library that accepts ICC profile strings. Returns `:unsupported_option`. |
| `t_<name>` | ❌ | Named (server-side alias) transformations are not modelled by the IR. Returns `:unsupported_option`. |
| `if_<predicate>` | ❌ | Conditional transforms not implemented. |
| `vc_<codec>` / `ac_<codec>` / `br_<rate>` | ❌ | Video-only options. Returns `:unsupported_option`. |

## Behavioural differences

### Multi-stage chained transforms collapse to one stage

Cloudinary lets you chain transforms with `/`: `w_200,c_fill/e_blur:300/q_auto`. Each stage runs as a separate transformation pass; later stages see the output of earlier ones. The canonical IR in v0.1 doesn't model multi-pass pipelines — all options compose into one Resize op, one Adjust op, etc.

The provider flattens the stages by joining them with `,` and processes them as a single set. For most useful transforms (resize + format + quality + a single effect) this is identical to Cloudinary. Recipes that genuinely require ordering (sharpen at original resolution → resize → sharpen at output resolution) lose information: only the second sharpen survives.

If you hit a real-world case where this matters, open an issue with the URL and the expected behaviour.

### Canonical-string for signing

Cloudinary's HMAC payload is `<transforms>/<source><api_secret>` — secret appended to the canonical string (not used as the HMAC key). The result is hashed with SHA-256 (we ship SHA-256 only; SHA-1 is legacy) and truncated to 32 url-safe-base64 characters. We replicate this exactly. URLs signed by Cloudinary's hosted service verify against an `image_plug` deployment with the same secret, and vice-versa. No wire-level translation needed.

### Account segment is required

Cloudinary URLs always carry an account segment (`<host>/<account>/image/upload/...`) even when self-hosted. The provider requires it structurally; configuring `:account` lets the provider reject mismatches with `:malformed_url` rather than silently routing them through.

### `q_auto` doesn't auto-tune quality

Cloudinary's `q_auto` (and its variants `q_auto:eco`, `q_auto:good`, `q_auto:best`) selects an output quality based on image content analysis. The Image library doesn't expose a content-aware quality knob, so we leave the encoder default (85) in place and set `compression: :fast`. This produces sensible output but isn't byte-identical to Cloudinary's hosted result.

## Conformance summary

| Category | Conformance | Notes |
| --- | --- | --- |
| URL forms | High | Single-stage upload + fetch + signed all wire-compatible; multi-stage flattens. |
| Sizing options (`w`/`h`/`c_`/`g_`/`x_`/`y_`) | High | `c_imagga_*` and `g_auto:*` approximated. |
| Output format (`f_`, `q_`, `dpr_`) | High | `q_auto` doesn't auto-tune; `dpr_` capped at 3. |
| Effects (`b_`/`e_blur`/`e_sharpen`/colour adjusts/`e_grayscale`/`e_replace_color`) | Medium | Common effects plus `e_replace_color` work; vignette/pixelate/cartoonify/fade/improve still deferred to `Image` upstream. |
| Geometry (`a_`/`bo_`) | Medium | `a_` 90-multiples only; `r_` and `o_` not implemented. |
| Overlays (`l_`) | Partial | Base layer form only. |
| Colour-space (`cs_`) | High | Named colorspaces (`srgb`, `tinysrgb`, `cmyk`, `no_cmyk`) supported; arbitrary ICC profiles deferred. |
| Signed URLs | Full | Wire-format-compatible with Cloudinary's hosted service (SHA-256 / 32 url-safe-base64 chars). |

## Reporting gaps

Open an issue at the project's GitHub. Include the request URL, the expected behaviour per Cloudinary's docs (with a link), and the actual response.
