# Plan 0003 — imgix provider for `image_plug` + adapter for `image_components`

Status: in progress.

## 1. Goals

* Add a second URL grammar to the project to validate that the pluggable provider/CDN seams (`Image.Plug.Provider`, `Image.Component.CDN`) are genuinely architecture-pluggable and not accidentally Cloudflare-shaped.

* Allow `image_plug` deployments to serve [imgix](https://docs.imgix.com)-style URLs interchangeably with Cloudflare-style URLs (one provider per mount point).

* Allow `image_components` to emit imgix-style URLs via `Image.Component.CDN.Imgix`, so the same `<.image>` markup can target Cloudflare, image_plug, *or* an imgix endpoint by switching the `:cdn` config.

* Keep the canonical pipeline IR unchanged. If we have to add fields to the IR to accommodate imgix, that's a sign the abstraction is leaky and worth a redesign.

## 2. Non-goals

* Full coverage of imgix's ~80 documented parameters. Implement the common subset that maps to our IR; document the gaps. Use the same `✅`/`⚠️`/`❌` marker convention as the Cloudflare conformance guide.

* Imgix-specific advanced features (text rendering, AI tagging, color-palette extraction, mp4 generation). Out of scope; would expand the IR.

* Reverse-proxy-mode imgix support (where imgix fetches from your origin and rewrites). The provider only handles the URL grammar — source resolution stays the host's responsibility via existing `SourceResolver` configuration.

## 3. URL grammar

Imgix URLs are query-string-driven, with the source path appearing literally in the path:

```
https://example.imgix.net/photos/sunset.jpg?w=800&h=600&fit=crop&auto=format
```

Two source modes per the [imgix docs](https://docs.imgix.com/en/latest/setup/serving-images/serving-asset-types):

* **Web folder source**: the path *is* the source key (`/photos/sunset.jpg`). The host's `SourceResolver` (typically `File` or `Hosted`) maps the path to bytes.

* **Web proxy source**: the path is a percent-encoded absolute URL (`/https%3A%2F%2Fassets.example.com%2Fsunset.jpg`). Treated as a URL source; resolved by `SourceResolver.HTTP`.

The `Image.Plug.Provider.Imgix.URL` recogniser distinguishes the two and emits the right `%Image.Plug.Source{kind: :path | :url}`.

### Mount semantics

* Cloudflare's URL has a `/cdn-cgi/image/` marker that lets a single mount serve both transformed images and other application routes. The Cloudflare provider parses it via path-prefix match.

* Imgix has no such marker — every request under the imgix domain is presumed to be a transform request. The provider parses the request path as the source path directly.

* Practical implication: an imgix-mounted plug should sit at the root of its own (sub)domain, or behind a path mount that the host's router forwards to entirely. The provider supports a `:mount` option that strips a leading prefix (e.g. `/img`) before treating the rest as source.

### Mixing providers in one app

`image_plug` is one provider per `init/1` call. To serve both Cloudflare-style and imgix-style URLs from one app, mount the plug twice:

```elixir
plug Image.Plug, provider: {Image.Plug.Provider.Cloudflare, []}, ...

# Mounted at /imgix-style/* via Plug.Router forward or a separate endpoint
forward "/imgix",
  to: Image.Plug,
  init_opts: [
    provider: {Image.Plug.Provider.Imgix, mount: "/imgix"},
    source_resolver: ...
  ]
```

Both share the same `SourceResolver` and `VariantStore` if the host wires them with the same configuration; or each can have its own.

## 4. Option-key mapping

Imgix has ~80 documented parameters. v0.1 of the provider implements the common subset that maps cleanly onto our existing canonical IR. The full conformance matrix lives in `guides/imgix_conformance.md` (drafted alongside the implementation).

### Sizing → `%Resize{}`

| imgix | Canonical IR | Notes |
| --- | --- | --- |
| `w=N` | `Resize{width: N}` | Same as `width=N` Cloudflare. |
| `h=N` | `Resize{height: N}` | Same as `height=N`. |
| `dpr=N` | `Resize{dpr: N}` | Same. Imgix accepts up to 5; we cap at 3 like Cloudflare. |
| `fit=clip` | `Resize{fit: :contain}` | "Fit within bounds preserving aspect." |
| `fit=clamp` | `Resize{fit: :contain}` (with edge-extend) | Imgix's `clamp` extends edge pixels rather than padding. We treat it as `:contain` for now and document the gap. |
| `fit=crop` | `Resize{fit: :cover}` | + crop position from `crop=...`. |
| `fit=facearea` | `Resize{fit: :cover, gravity: :face}` | Maps to face-aware crop. |
| `fit=fill` | `Resize{fit: :pad}` | Combined with `bg=` from imgix maps to our `Background` op. |
| `fit=fillmax` | `Resize{fit: :scale_down}` then pad | Two-step; emit Resize + Background ops. |
| `fit=max` | `Resize{fit: :scale_down}` | Never upscale. |
| `fit=min` | `Resize{fit: :scale_down}` (capped at smaller dimension) | Imgix's `min` is the inverse of `max`; we approximate. |
| `fit=scale` | `Resize{fit: :squeeze}` | Force exact dimensions. |
| `crop=top` | `Resize{gravity: :north}` | Combined with `fit=crop`. |
| `crop=bottom` | `Resize{gravity: :south}` | |
| `crop=left/right` | `Resize{gravity: :west/:east}` | |
| `crop=faces` | `Resize{gravity: :face}` | |
| `crop=entropy` | `Resize{gravity: :auto}` | Maps to libvips `:entropy` crop. |
| `crop=focalpoint` + `fp-x`/`fp-y` | `Resize{gravity: {:xy, fp_x, fp_y}}` | Focal point as normalised 0..1. |

### Output / format → `%Format{}`

| imgix | IR | Notes |
| --- | --- | --- |
| `q=N` | `Format{quality: N}` | 0..100, same range. |
| `fm=jpg` | `Format{type: :jpeg}` | |
| `fm=png` | `Format{type: :png}` | |
| `fm=webp` | `Format{type: :webp}` | |
| `fm=avif` | `Format{type: :avif}` | |
| `fm=jp2` | n/a | Out of scope; we don't encode JPEG 2000. Returns `:invalid_option`. |
| `auto=format` | `Format{type: :auto}` | Same Accept-driven negotiation as Cloudflare. |
| `auto=compress` | `Format{compression: :fast}` | Multi-value: `auto=format,compress` splits to both effects. |
| `auto=enhance` | n/a | Image-content-aware enhancement; out of scope. |

### Effects

| imgix | IR |
| --- | --- |
| `bg=<hex>` | `Background{color: ...}` |
| `blur=N` (0..2000) | `Blur{sigma: N / 100}` (calibrated to match Cloudflare's `blur=N`) |
| `sharp=N` (0..100) | `Sharpen{sigma: N / 10}` |
| `bri=N` (-100..100) | `Adjust{brightness: 1 + N/100}` |
| `con=N` (-100..100) | `Adjust{contrast: 1 + N/100}` |
| `sat=N` (-100..100) | `Adjust{saturation: 1 + N/100}` (`-100` ≈ greyscale) |
| `gam=N` (-100..100) | `Adjust{gamma: 1 + N/100}` |
| `monochrome=<hex>` | `Adjust{saturation: 0}` + `Background{color: hex}` overlay (approximation) |
| `sepia=N` | n/a in v0.1 — IR has no sepia op. Return `:invalid_option` until added. |

### Geometry

| imgix | IR |
| --- | --- |
| `flip=h` / `v` / `hv` | `Flip{direction: ...}` |
| `rot=N` | `Rotate{angle: N}` (multiples of 90 only). |
| `or=N` | EXIF orientation override. v0.1: ignored with a warning. |
| `trim=auto` | `Trim{mode: :border}` |
| `trim=color` + `trimcolor=<hex>` | `Trim{mode: :border, color: ...}` |
| `border=W,<hex>` | `Border{color, top: W, right: W, bottom: W, left: W}` |

### Drawing / overlays

| imgix | IR |
| --- | --- |
| `mark=<url>` | `Draw.Layer{source: Source.url(url)}` |
| `mark-w` / `mark-h` | layer width/height |
| `mark-x` / `mark-y` | layer position offsets |
| `mark-fit` | layer fit mode |
| `mark-rot` | layer rotation |
| `mark-pad` | layer padding (no IR field; rendered as offset adjustment) |
| `markalign=top,left` etc. | named position → corner offsets |

### Misc

| imgix | IR |
| --- | --- |
| `cs=srgb` / `cs=adobergb1998` | colour-space conversion. v0.1: ignored with a warning. |
| `expires=N` | URL expiry (signing). Maps to our `?exp=N`. |
| `s=<hex>` | URL signature. Verified by `Image.Plug.Provider.Imgix` before pipeline parse, mirroring how the Cloudflare provider handles `?sig=`. |

## 5. Module layout

### `image_plug` (server)

```
lib/image/plug/provider/
  imgix.ex                          # Image.Plug.Provider.Imgix — wires URL + Options
  imgix/
    url.ex                          # Path/query split, source recognition, mount strip
    options.ex                      # Per-key parser; emits canonical IR ops
    signing.ex                      # Imgix HMAC-SHA1 (legacy) / SHA-256 with ?s=
```

`Image.Plug.Provider.Imgix` implements the existing `Image.Plug.Provider` behaviour (`parse/2`). No changes to the behaviour itself.

For signing, imgix uses a different parameter name (`s` vs Cloudflare's `sig`) and signs over `path + ? + query` always (not just when query is non-empty). Rather than retrofitting `Image.Plug.Signing` to take a parameter name + payload-construction strategy, ship `Image.Plug.Provider.Imgix.Signing` as a sibling with the same behaviour API but imgix's wire format. The plug's `:signing` config either takes the generic `Image.Plug.Signing` (used by the Cloudflare provider) or per-provider when configured by the provider itself; design lands in implementation.

### `image_components` (client)

```
lib/image/component/cdn/
  imgix.ex                          # implements Image.Component.CDN
  imgix/
    url.ex                          # Builds imgix-grammar URLs from canonical options
    signing.ex                      # Imgix sign helper
```

`Image.Component.CDN.Imgix` implements the existing `Image.Component.CDN` behaviour. Atom shorthand: `cdn: :imgix`. Per-call: `<.image cdn={:imgix} ... />`.

The `:host` and `:scheme` options behave the same way as for Cloudflare; the `:mount` option is rarely useful for imgix (since imgix has no path marker) but is still honoured.

### Canonical option keys

The component takes the same Cloudflare-flavoured option keys (`:width`, `:height`, `:fit`, `:format`, `:quality`, etc.) regardless of which CDN the URL targets. Each adapter translates from those canonical names to its CDN's wire format. Users don't need to learn imgix's `w`/`h`/`fm` shorthand — they pass `width: 800, format: :webp` and the imgix adapter encodes `w=800&fm=webp`.

## 6. Signing

Imgix signing (per [docs](https://docs.imgix.com/en/latest/setup/securing-images)):

* HMAC-SHA256 (or legacy SHA-1; we ship SHA-256 only).
* Key: a per-source-key secret token.
* Payload: `secret <> path <> "?" <> query` where the query excludes the `s` parameter. When query is empty, the payload is `secret <> path` with no trailing `?`.
* Hex digest, lowercase.
* Parameter: appended as `&s=<hex>` (or `?s=<hex>` if no other params).

Differences from Cloudflare:

* Parameter name: `s` vs `sig`.
* Algorithm matches (SHA-256).
* Canonical-string rule: imgix prepends the secret to the payload; Cloudflare uses the secret as the HMAC key only. This is the substantive wire-format difference.

Implementation: `Image.Plug.Provider.Imgix.Signing.sign/3` and `verify/3` mirror the public API of `Image.Plug.Signing` so the plug-level `:signing` config can swap between them per-provider.

Configuration shape:

```elixir
plug Image.Plug,
  provider: {Image.Plug.Provider.Imgix, [
    signing: %{keys: ["secret-token"], required?: true}
  ]}
```

The `:signing` is *provider*-level rather than plug-level for imgix because imgix's signing is part of the imgix grammar (the parameter is `?s=` per the spec). Cloudflare's signing remains plug-level since we invented the wire format.

## 7. Phasing

Each phase ships independently with the four-check DoD gate green.

**Phase A — server URL recogniser.** `Image.Plug.Provider.Imgix.URL.parse/2` distinguishes web-folder vs web-proxy sources, strips `:mount`, returns `%{shape: :imgix, options: query_string, source: %Source{}}`. Unit tests only.

**Phase B — server options parser.** `Image.Plug.Provider.Imgix.Options.parse/2` reads the query string, maps each key onto canonical IR ops. Tests for every documented key with valid + invalid values.

**Phase C — server provider wiring + signing.** `Image.Plug.Provider.Imgix.Signing` implements sign/verify; `Image.Plug.Provider.Imgix` chains URL → optional signature verification → Options → IR. Integration tests via the existing `Image.Plug.IntegrationCase` harness. Property tests where they make sense (compliant/invalid value sweeps per option).

**Phase D — client CDN adapter.** `Image.Component.CDN.Imgix` implements `Image.Component.CDN`. `build_url/2` translates canonical options to imgix wire format. `sign_url/3` matches the server's verifier. Unit tests + a round-trip test that signs on the client and verifies on the server.

**Phase E — guides.**
* New `image_plug/guides/imgix_conformance.md` with the same `✅`/`⚠️`/`❌` table format as the Cloudflare guide.
* Update `image_plug/guides/usage.md` "Mounting" section to show two-provider setup.
* Update `image_components/guides/usage.md` "Picking a CDN" section to add `:imgix` to the documented atom shorthand and show a worked example.

**Phase F — DoD on both packages.**

## 8. Definition of done

Standard four-check gate, plus:

* Round-trip test: a URL produced by `Image.Component.CDN.Imgix.build_url/2` is parseable by `Image.Plug.Provider.Imgix.parse/2` and produces a pipeline that, when executed, yields an image with the dimensions/format encoded in the URL.

* Round-trip signing: a URL signed by `Image.Component.CDN.Imgix.sign_url/3` verifies under `Image.Plug.Provider.Imgix.Signing.verify/3` with the same key.

* `cloudflare_conformance.md` and `imgix_conformance.md` are both ✅/⚠️/❌-marked, both reachable from the Guides sidebar.

* No new fields added to the canonical IR. (If we needed to add a field, that's a separate plan to renegotiate the abstraction first.)

## 9. Resolved decisions

1. **Signing algorithm**: SHA-256 only. SHA-1 (legacy) is documented as unsupported.

2. **`fit=clamp`**: implement properly via `Image.embed/4` `extend: :copy`. Small extra surface, real visual difference.

3. **Multi-value `auto=` parameter**: split in `Options.parse/2` before per-key dispatch.

4. **`mark=<url>` overlay**: doc-only. If the host's `SourceResolver` doesn't handle `:url`, the overlay errors with `:invalid_option` — caveat noted in the imgix conformance guide.

5. **Imgix-only features that don't fit the IR**: reject with a new `:unsupported_option` error tag so users learn early rather than getting silent no-ops. The error message names the unsupported feature and points at the conformance guide. Affected keys for v0.1: `auto=enhance`, `sepia`, `cs`, `monochrome` (legacy partial), `or` (EXIF orientation override). Each becomes ✅ as the underlying `Image` library helper lands (see `TODO.md` "Image sibling library: operations needed by CDN adapters").

