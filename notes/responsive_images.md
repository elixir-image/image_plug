# Responsive image tagging — research note

Captured during TODO 4 work. Two parallel research streams: (1) current best practice for HTML image markup, (2) the existing library landscape we should build on rather than reinvent.

## Current best practice (2025)

* **Decision tree.** Plain `<img>` for fixed-size UI chrome. `<img srcset sizes>` for the same image at multiple resolutions (resolution switching). `<picture>` with multiple `<source type>` only when (a) the crop/aspect ratio differs by breakpoint (art direction) or (b) format negotiation (AVIF/WebP/JPEG) is in play. Per [WHATWG "Pick an image source"](https://html.spec.whatwg.org/multipage/images.html#pick-an-image-source).

* **`srcset` flavours.** Width descriptors (`200w 400w 800w`) plus `sizes` for fluid layouts. DPR descriptors (`1x 2x`) only when the rendered CSS size is fixed regardless of viewport (logo, fixed-size avatar). Mixing the two in one `srcset` is invalid.

* **`<picture>` format ordering.** Most modern format first; `type` attribute mandatory or browsers cannot skip unsupported formats. Canonical 2025 ladder: AVIF → WebP → JPEG/PNG. AVIF support is ~95% globally per [caniuse.com/avif](https://caniuse.com/avif): Chrome 85+, Firefox 113+, Safari 16.4+, Edge 121+. Safe to lead with.

* **Performance attributes.** Always set intrinsic `width` and `height` (CLS prevention, even with CSS sizing). `loading="lazy"` for below-the-fold; never on the LCP image. `decoding="async"` is a safe default everywhere. `fetchpriority="high"` on the LCP image is the modern replacement for `<link rel="preload" as="image">` (Chrome 102+, Safari 17.2+, Firefox 132+). Per [web.dev "Optimize Largest Contentful Paint"](https://web.dev/articles/optimize-lcp).

* **`sizes` attribute.** Compute from the actual CSS width per breakpoint, not from the viewport. `sizes="auto"` (Chrome 123+, Firefox 123+, Safari 18.4+) only valid with `loading="lazy"`; provide an explicit fallback with `sizes="auto, 100vw"`.

* **Default width ladder.** A defensible default: `320, 480, 640, 800, 1024, 1280, 1600, 1920, 2560`. Trim per-component when the image's max rendered width is constrained.

* **Anti-patterns.** Lazy-loading the hero. CSS background-images for the LCP element (invisible to the preload scanner). Client-side `<img>` injection. Missing `width`/`height`. Mixing `w` and `x` in one `srcset`.

## Library landscape

* **Elixir / Phoenix.** The ecosystem is essentially empty. `phoenix_srcset` (4 weekly downloads, 0 stars, ImageMagick-based pre-build approach, no CDN-URL awareness). `img_cf` (Cloudflare-aware Phoenix component but unmaintained since 2021, predates LiveView function components). `imgex` and `cloudex` are URL/upload helpers, not responsive-markup generators. There is no maintained Elixir component that builds responsive `<img srcset>` against any image-CDN URL grammar.

* **JavaScript.** [`unpic`](https://github.com/ascorbic/unpic) is the dominant project — 131k weekly npm downloads on the core, 88k on `@unpic/react`, 11k on `@unpic/astro`, 415 stars on core / 2,034 stars on `unpic-img`, last push 2026-04-22. MIT-licensed. Crucially, it ships first-class providers for both Cloudflare URL grammars `Image.Plug` already speaks: `cloudflare` (Workers `/cdn-cgi/image/<options>/<source>`) and `cloudflare_images` (`imagedelivery.net/<account>/<image>/<variant>`). It also encodes the canonical responsive width ladder, the `sizes` → srcset width-list algorithm, layout modes (`fixed | constrained | fullWidth`), DPR handling, and `<img>` attribute hygiene.

* **Server-rendering frameworks.** Next.js `<Image>`, Astro `<Image>`/`<Picture>` (which recommends `@unpic/astro` as drop-in), Eleventy Image (build-time only — not relevant). The shared architecture is the same four-layer stack: (a) URL builder per CDN, (b) fixed responsive width ladder, (c) `sizes`-aware srcset generator, (d) thin component that wires it into `<img>` attributes with sensible defaults.

## Decision

**Port unpic's algorithm to Elixir; ship a single `<.image>` Phoenix function component on top of it.** Wrapping `phoenix_srcset` is not viable (4 weekly downloads); spawning a Node sidecar to call unpic from a LiveView render path is absurd; building from scratch underestimates the cumulative bug-fixes baked into 131k weekly downloads of real-world feedback.

The Cloudflare URL grammar `Image.Plug` already accepts is the same grammar unpic's `cloudflare` provider emits. That makes the port double as an interop spec: any URL `Image.Plug` accepts, the component should produce.

### Suggested module shape

* `Image.Plug.Component.URL` — Cloudflare URL builder (port of [`unpic/src/providers/cloudflare.ts`](https://github.com/ascorbic/unpic/blob/main/src/providers/cloudflare.ts)). Always compiled.

* `Image.Plug.Component.Srcset` — width-ladder + sizes parser + srcset string builder (port of `@unpic/core` `transformProps`). Always compiled.

* `Image.Plug.Component` — the `Phoenix.Component`. Conditionally compiled with `if Code.ensure_loaded?(Phoenix.Component)` so adding `phoenix_live_view` to a host project unlocks the component without making it a hard dependency of `image_plug`.

### Recommended component API

```heex
<.image
  src="/photos/sunset.jpg"
  sizes="(min-width: 1200px) 800px, (min-width: 768px) 50vw, 100vw"
  widths={[320, 480, 800, 1280]}
  formats={[:avif, :webp, :jpeg]}
  alt="Sunset over the harbour"
  width={1600}
  height={900}
  priority={:lcp}
  loading={:auto}
/>
```

Emits:

* A `<picture>` when more than one format is requested (or art-direction sources are provided).

* A bare `<img srcset sizes>` otherwise.

* `priority: :lcp` auto-promotes to `loading="eager" fetchpriority="high" decoding="async"`.

### Reference

Key URLs to consult during the full port:

* [`unpic/src/providers/cloudflare.ts`](https://github.com/ascorbic/unpic/blob/main/src/providers/cloudflare.ts)
* [`unpic/src/providers/cloudflare_images.ts`](https://github.com/ascorbic/unpic/blob/main/src/providers/cloudflare_images.ts)
* [`unpic-img/packages/core/src`](https://github.com/ascorbic/unpic-img/tree/main/packages/core/src)
* [unpic algorithm docs](https://unpic.pics/img/)
