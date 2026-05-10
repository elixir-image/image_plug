# IIIF Image API 3.0 conformance

This guide documents `image_plug`'s conformance to the [IIIF Image API 3.0](https://iiif.io/api/image/3.0/) specification — what we implement, what we deliberately don't, and the [Compliance Level](https://iiif.io/api/image/3.0/compliance/) we target.

The reference is the [IIIF Image API 3.0 specification](https://iiif.io/api/image/3.0/) and the [IIIF Image API Validator](https://iiif.io/api/image/validator/). When this guide and the IIIF spec disagree, treat the spec as the contract and file an issue against `image_plug`.

## Compliance level

`image_plug`'s IIIF provider targets **[Compliance Level 2](https://iiif.io/api/image/3.0/compliance/)**. Level 2 is the level most production servers (Cantaloupe, Loris, IIPImage) implement; it covers the full set of region / size / rotation / quality / format combinations that real IIIF clients (Universal Viewer, Mirador, OpenSeadragon) need.

We do not currently target Level 3 (which adds more granular size syntax and per-feature negotiation).

## URL forms recognised

| Form | IIIF | `image_plug` | Notes |
| --- | --- | --- | --- |
| `<prefix>/<id>/<region>/<size>/<rotation>/<quality>.<format>` | ✅ | ✅ | The standard image-request URL. All five segments required. |
| `<prefix>/<id>/info.json` | ✅ | ✅ | The Image Information document. Returned as `application/ld+json`. |
| `<prefix>/<id>` (bare identifier) | ✅ (303 redirect to info.json) | ⚠️ | Currently rejected with `:malformed_url`. Roadmap: add the 303. |

The `<prefix>` segment is fully configurable via the `:endpoint` option — `"iiif/3"` (default), `"image"`, `""` (mount-root), or anything else. The plug's outer mount path is also stripped before recognition via the `:mount` option.

## Region segment

| Form | `image_plug` | Notes |
| --- | --- | --- |
| `full` | ✅ | No `Crop` op produced. |
| `square` | ⚠️ | Parses as `pct:0,0,100,100` (whole image). True centred-square requires source-aware computation; the lossy fallback is documented. |
| `<x>,<y>,<w>,<h>` (pixels) | ✅ | `Ops.Crop{units: :pixels}`. Out-of-bounds regions are clamped at apply time per spec §4.1. |
| `pct:<x>,<y>,<w>,<h>` | ✅ | `Ops.Crop{units: :percent}`. Resolved against actual source dimensions at apply time. |

## Size segment

| Form | `image_plug` | Notes |
| --- | --- | --- |
| `max` | ✅ | `Ops.Resize{upscale?: false}` — no dimension constraints; the source size becomes the output size. |
| `^max` | ✅ | `Ops.Resize{upscale?: true}` — the `^` permits upscaling. |
| `<w>,` | ✅ | Width-only resize; height computed from source aspect. |
| `,<h>` | ✅ | Height-only resize. |
| `<w>,<h>` | ✅ | Distorts to exact dimensions (`fit: :squeeze`). |
| `!<w>,<h>` | ✅ | Fits within the bounding box, preserving aspect (`fit: :contain`). |
| `pct:<n>` | ✅ | Resize by percentage; mapped to `Ops.Resize{size_pct: n}`. |
| `^` prefix on any of the above | ✅ | Sets `Resize.upscale?: true`. |

## Rotation segment

| Form | `image_plug` | Notes |
| --- | --- | --- |
| `0` | ✅ | Dropped by the normaliser. |
| Integer `1`–`360` | ✅ | `Ops.Rotate{angle: n}` (integer preserved). |
| Float `0.0`–`360.0` | ✅ | `Ops.Rotate{angle: n}` (float preserved). |
| `!N` (mirror-then-rotate) | ⚠️ | The angle parses correctly but the leading mirror is silently dropped — there is no `Mirror` op in the IR yet. Roadmap. |

## Quality segment

| Form | `image_plug` | Notes |
| --- | --- | --- |
| `default` | ✅ | No quality-related op. |
| `color` | ✅ | Treated identically to `default` (the spec allows this). |
| `gray` | ✅ | `Ops.Adjust{saturation: 0.0}`. |
| `bitonal` | ✅ | `Ops.Posterize{levels: 2}`. |

The IIIF spec lists `default`, `color`, `gray`, `bitonal` as the four base qualities. Servers MAY advertise more under `extraQualities` in info.json; we do not.

## Format segment

| Extension | IR `Format.type` | Notes |
| --- | --- | --- |
| `jpg`, `jpeg` | `:jpeg` | Always supported. |
| `png` | `:png` | Always supported. |
| `gif` | `:gif` | Always supported (libvips bundled). |
| `webp` | `:webp` | Always supported (libvips bundled). |
| `tif`, `tiff` | `:tiff` | Gated on `Image.Plug.Capabilities.tiff_write?/0` (most builds support it). |
| `jp2` | `:jp2` | Gated on `Image.Plug.Capabilities.jp2_write?/0` (requires libvips built with `libopenjp2`). |
| `pdf` | `:pdf` | Gated on Cairo support; advertised conditionally. |

The info.json document advertises only the formats this build can actually produce.

## info.json discovery document

The `<id>/info.json` endpoint serves the IIIF [Image Information document](https://iiif.io/api/image/3.0/#5-image-information). What we emit:

| Property | Value | Notes |
| --- | --- | --- |
| `@context` | `http://iiif.io/api/image/3/context.json` | The Image API 3.0 JSON-LD context. |
| `id` | The canonical service URL | Reconstructed from the request URL with `/info.json` stripped. |
| `type` | `ImageService3` | |
| `protocol` | `http://iiif.io/api/image` | |
| `profile` | `level2` | We're a Level 2 server. |
| `width`, `height` | Source dimensions | Read from the source resolver at request time. |
| `extraQualities` | `["gray", "bitonal"]` | Plus the always-supported `default` and `color`. |
| `extraFormats` | Capability-gated subset of `["webp", "tif", "jp2", "avif"]` | Always advertise `webp`; gate the others on `Image.Plug.Capabilities`. |
| `extraFeatures` | The standard Level 2 set | See `Image.Plug.Provider.IIIF.InfoJson` source for the full list. |

Response headers:

* `Content-Type: application/ld+json`
* `Link: <http://iiif.io/api/image/3/level2.json>;rel="profile"` (per spec §6)
* `Cache-Control: public, max-age=86400` (info.json is highly cacheable)

What we do **not** emit (Level 3 / Image API 4.0 features):

* `sizes` and `tiles` arrays — the discrete-tile and pyramid-aware features used by IIIF zoom-image viewers.
* `service` extensions — auth, search, content-state.
* `partOf`, `seeAlso`, `rights` JSON-LD relations.

These are non-blocking for image-rendering clients but block heavyweight viewers like OpenSeadragon's pyramid mode. Roadmap.

## Mounting the IIIF provider

```elixir
forward "/iiif/3", Image.Plug,
  provider: {Image.Plug.Provider.IIIF, []},
  source_resolver: {Image.Plug.SourceResolver.File, root: "/var/lib/iiif"}
```

Or with a custom endpoint path:

```elixir
forward "/imageserver", Image.Plug,
  provider: {Image.Plug.Provider.IIIF, [endpoint: "iiif/3"]},
  source_resolver: {Image.Plug.SourceResolver.File, root: "/var/lib/iiif"}
```

The full source-resolver story (file, HTTP, S3, custom) is in [`sources.md`](sources.md). The CDN-fronting story (CloudFront/Fastly/Cloudflare in front of the IIIF mount) is in [`cdn_origin.md`](cdn_origin.md) — IIIF's URL grammar is just as cache-friendly as the four CDN providers.

## Known gaps and roadmap

* **`square` region as true centred-square** — needs source-aware computation in the parser, or a `:square` mode on `Ops.Crop`. Currently a `pct:0,0,100,100` fallback (whole image).
* **`!N` mirror-then-rotate** — angle parses; mirror is silently dropped. Add an `Ops.Mirror` op or a flag on `Rotate`.
* **`<id>` bare-identifier 303 redirect** — currently rejected with `:malformed_url`. Spec-required redirect to `<id>/info.json`.
* **info.json `sizes` / `tiles` arrays** — needed for IIIF tile-pyramid clients (OpenSeadragon, Universal Viewer's pyramid mode).
* **Authentication / Authorization API integration** — IIIF Image API can sit behind the IIIF Auth API; not modelled.

## Related

* [`sources.md`](sources.md) — source resolution, including the S3 worked example.
* [`cdn_origin.md`](cdn_origin.md) — running `image_plug` as the origin behind a CDN; applies equally to the IIIF mount.
* [`face_aware.md`](face_aware.md) — face-aware crops; not used by IIIF (no `gravity=face` equivalent in the IIIF spec).
* [`image_components`'s IIIF guide](https://hexdocs.pm/image_components/iiif.html) — the client-side story; how `<.image provider={:iiif}>` produces URLs this provider parses.
