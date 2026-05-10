# `image_plug` as a CDN-side service

This guide explains how to deploy `image_plug` as the *origin* behind an HTTP cache layer — a CDN like CloudFront, Fastly, or Cloudflare, or a local cache like nginx — so the heavy work of decoding, transforming, and re-encoding happens once per unique transformed URL, and every subsequent hit is served from the cache without ever touching libvips again.

This is the recommended deployment pattern for self-hosted image processing at any non-trivial scale. It is a different model from "use the Cloudflare Images / Cloudinary / imgix / ImageKit edge directly", which is what `image_components` projects URLs for; both are valid and `image_plug` exists to make the self-hosted side as fast and as cacheable as the edge service is.

## The model

```
   Browser ─► CDN edge ─► image_plug ─► libvips ─► transformed bytes
              (cache)      (origin)
                ▲              │
                └──────────────┘
                first request: cache miss → origin compute
                subsequent requests: cache hit → no origin call
```

The contract between CDN and `image_plug` is plain HTTP: the CDN forwards the request unmodified, `image_plug` returns the transformed bytes plus cache headers, and the CDN caches by URL and serves all matching subsequent requests from its edge nodes. `image_plug` does not need to know there is a CDN in front of it; CDNs do not need to know there is image processing happening behind them.

## Why this works for `image_plug` specifically

Three properties of `image_plug` make it a particularly good origin for CDN caching:

* **The URL is the cache key.** Every transform parameter rides in the URL itself (`/cdn-cgi/image/width=600,fit=cover,format=webp/cat.jpg`). The CDN's natural by-URL cache key is therefore the natural by-transform cache key — no `Vary` on query strings, no per-cookie variation, no auth headers in the cache key.

* **The pipeline is normalised before the ETag is computed.** `Image.Plug.Pipeline.Normaliser.normalise/1` sorts options into a canonical order before fingerprinting, so two URLs that differ only in option order (`width=600,fit=cover` vs `fit=cover,width=600`) produce *the same strong ETag*. CDNs that key on URL will treat them as separate cache entries, but the conditional-GET behaviour is consistent: a `If-None-Match` against the second URL will 304 against the first URL's ETag.

* **The origin response is deterministic and idempotent.** Same source bytes + same pipeline = byte-identical output. There is no per-request randomness, no time-dependent state, nothing that would force a CDN to revalidate. A cache entry is valid until either the source changes (rare) or you explicitly evict it.

## The headers `image_plug` emits

Every successful response carries:

* `ETag: "<strong>"` — base64url-encoded SHA-256 of `meta.etag_seed <> "|" <> pipeline_fingerprint <> "|" <> chosen_format`. Strong validator (no `W/` prefix). Two URLs that produce the same bytes produce the same ETag.

* `Cache-Control: public, max-age=3600, stale-while-revalidate=86400` by default. Override per-source via `meta.cache_control` from the source resolver, or per-mount via the plug's configuration.

* `Vary: Accept` when the pipeline used `format=auto`. Tells the CDN to differentiate cache entries by the client's `Accept` header so a Chrome client (which gets AVIF) and a legacy Safari client (which gets WebP or JPEG) hit different cache entries despite sharing the URL.

* `Last-Modified: <RFC 1123 date>` when the source resolver populated `meta.last_modified`. The default `File` resolver does this from the file's mtime; the `HTTP` resolver does not (response headers aren't surfaced through the streaming decode path).

* `Content-Type: image/<format>` for the chosen output format.

Conditional GET via `If-None-Match` returns `304 Not Modified` without invoking libvips at all — the ETag is computed from the source meta and the pipeline fingerprint, neither of which requires opening the image.

When the encoder couldn't satisfy the requested format (e.g. AVIF without `libaom`), the response also carries `x-image-plug-format-fallback: avif->webp`. This is informational; CDNs key on URL, not on this header.

## Tuning `Cache-Control` for an image origin

The default `max-age=3600, stale-while-revalidate=86400` is conservative — sensible for unknown sources, but rarely what you want for image-CDN traffic. The right values depend on whether your URLs are *immutable* or *mutable*.

### Immutable URLs (recommended)

If your source paths are content-addressed — e.g. `/uploads/<sha256>.jpg` — then the URL identifies the bytes uniquely and forever. The transformed URL inherits that immutability: `/cdn-cgi/image/width=600/uploads/<sha>.jpg` will always produce the same bytes for the same source. In that case the cache headers should say so:

```elixir
# In your source resolver:
{:ok, image,
 %{
   content_type: "image/jpeg",
   etag_seed: "<sha>",
   cache_control: "public, max-age=31536000, immutable",
   immutable?: true
 }}
```

`max-age=31536000` (one year) plus the `immutable` directive tells browsers and CDNs to never revalidate. Coupled with content-addressed source paths (which `image_playground`'s `Uploads` module does by default), this is the configuration that lets a CDN serve the long tail of transforms without ever round-tripping back to your origin.

### Mutable URLs

If a source path can change content under the same URL — `/uploads/avatar.jpg` overwritten when the user uploads a new avatar — `immutable` is wrong; use a shorter `max-age` plus `stale-while-revalidate`:

```elixir
{:ok, image,
 %{
   content_type: "image/jpeg",
   etag_seed: "#{path}|#{stat.size}|#{mtime_unix}",  # changes when bytes change
   cache_control: "public, max-age=300, stale-while-revalidate=3600"
 }}
```

The `etag_seed` should incorporate something that changes when the bytes change (file size, mtime, an upstream ETag) so a content swap invalidates the ETag and the CDN's `If-None-Match` revalidation produces a 200 with new bytes instead of a stale 304.

## Recipe: CloudFront in front of `image_plug`

CloudFront is the most common pairing for AWS-hosted deployments. The minimum viable setup:

```
[browser] ─► CloudFront distribution ─► Origin (image_plug behind ALB / nginx / direct)
              cache policy: "image_plug"
```

In CloudFront terminology you need one Distribution, one Origin pointing at your `image_plug` host, and one Cache Policy that:

* **Includes the URL path in the cache key.** This is the default — leave it on.
* **Includes the `Accept` header in the cache key** (only when you serve `format=auto`). CloudFront will not include client headers in the cache key by default; explicitly add `Accept` to the cache policy's "Headers" list.
* **Excludes cookies and query strings from the cache key.** Default. Don't add them.
* **Honours origin `Cache-Control`.** This is the default behaviour with the `CachingOptimized` managed policy or any custom policy that doesn't override TTLs.

Origin-side, set `image_plug` to emit long `max-age` values (see "Immutable URLs" above) so CloudFront's edge caches keep transformed bytes for as long as possible.

For invalidation when you redeploy with breaking changes (e.g. a libvips bump that produces visibly different output), use CloudFront's invalidation API on a versioned path prefix (`/v2/...`) rather than wildcarding `/*`, which is slow and expensive.

## Recipe: Fastly (VCL or Compute@Edge) in front of `image_plug`

Fastly's default behaviour is closer to the model `image_plug` expects: it honours origin `Cache-Control`, keys the cache on URL + `Vary` headers, and supports surrogate keys for tag-based invalidation. The minimal VCL is essentially empty.

Add `Surrogate-Key` headers from the source resolver if you want tag-based purge:

```elixir
# In a custom source resolver:
{:ok, image,
 %{
   content_type: "image/jpeg",
   etag_seed: etag,
   cache_control: "public, max-age=31536000, immutable",
   # `Image.Plug.Cache` does not currently emit Surrogate-Key — set it
   # in a Plug after Image.Plug if you need Fastly tag-based invalidation.
 }}
```

Then on Fastly, `purge --soft` against the surrogate key (e.g. `purge user:1234`) invalidates every transform of every avatar belonging to user 1234, without requiring you to enumerate URLs.

## Recipe: Cloudflare in front of `image_plug`

Cloudflare is interesting because it can sit in front of `image_plug` *and* serve as the URL-grammar source — your `image_components` `<.image>` tags emit `/cdn-cgi/image/...` URLs that Cloudflare itself recognises (via Cloudflare Images), and your origin recognises (via `Image.Plug.Provider.Cloudflare`). You can flip between "Cloudflare does the transform" and "image_plug does the transform" without changing application code.

If you just want Cloudflare as a basic cache (not Cloudflare Images), enable the "Cache Everything" page rule for the `/cdn-cgi/image/*` path and set Edge Cache TTL to honour origin headers. Cloudflare will respect your `Cache-Control: max-age=31536000, immutable` and the `Vary: Accept` for `format=auto` content negotiation.

For an explicit purge, `cf purge` against the URL pattern works; for app-driven invalidation, use Cloudflare's API.

## Recipe: nginx as a local cache layer

When you don't want a CDN — single-host deployment, internal app, on-prem — `nginx` can play the same role:

```nginx
proxy_cache_path /var/cache/image_plug levels=1:2 keys_zone=img:100m
                 max_size=10g inactive=30d use_temp_path=off;

server {
    listen 80;

    location /img/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_cache img;
        proxy_cache_key "$scheme$host$request_uri$http_accept";
        proxy_cache_valid 200 304 30d;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        add_header X-Cache-Status $upstream_cache_status;
    }
}
```

Three knobs worth understanding:

* **`proxy_cache_lock on`** — when N concurrent requests arrive for the same uncached URL, only one is forwarded to `image_plug`; the rest wait for the first to populate the cache. This prevents *cache stampede* on first-render of a popular transformed URL — important when libvips is doing real work.

* **`proxy_cache_key "$scheme$host$request_uri$http_accept"`** — including `$http_accept` is the nginx equivalent of `Vary: Accept`. Required when serving `format=auto`; omit it if every URL specifies an explicit `format=`.

* **`proxy_cache_use_stale ... updating`** — serve stale bytes while a background revalidation is in flight. Combined with the long `proxy_cache_valid 30d` plus origin `max-age=31536000, immutable`, this makes the steady-state path 100% cache hits with revalidation only on the cold-cache window after a purge.

## URL stability and cache invalidation

Cache invalidation is "the second hardest problem in computer science" because most caches don't have a clean handle on *which* entries to evict. With `image_plug` you have several:

* **Per-URL purge** — every CDN supports it. Cheap if you can enumerate the URLs you want to purge; expensive otherwise.

* **Path-prefix purge** — also widely supported. Useful when your URL paths are organised by tenant or asset type (`/img/cdn-cgi/image/*/uploads/user-123/*`).

* **Surrogate keys** (Fastly, Akamai, Cloudflare) — tag-based. The most flexible: tag every transformed response with the source's logical identity (`user:123`, `post:abc`), then purge by tag when the underlying entity changes.

* **Versioned paths** — bake a version into your source paths (`/v2/uploads/...`) and bump it when you want a global invalidation. CDN caches the new version cold; old version ages out passively. No purge call required.

For mostly-immutable image traffic (the common case), versioned paths plus content-addressing make explicit invalidation almost never necessary. The one case it does come up is when `image_plug` itself or libvips changes in a way that produces visibly different bytes from the same source + URL — version the URL prefix at deploy time and let the old cache age out.

## `Vary: Accept` and content negotiation

`format=auto` is a content-negotiation feature: the response format depends on the client's `Accept` header (Chrome → AVIF, modern Safari → AVIF/WebP, legacy clients → JPEG). `image_plug` emits `Vary: Accept` on these responses so the cache differentiates entries by `Accept`.

This works correctly with all major CDNs *if you remember to include `Accept` in the cache key*. CloudFront and Cloudflare default to URL-only cache keys; Fastly and nginx honour `Vary` natively. The recipes above all include the `Accept` step where relevant.

A common mistake is to omit `Accept` from the cache key, then notice that some users get the "wrong" format. The fix is always at the cache layer, not in `image_plug`.

If `format=auto` is not used (you always specify `format=webp` or similar), `Vary: Accept` is not emitted and `Accept` does not need to be in the cache key. Specifying explicit formats is the simpler path; `format=auto` exists for callers who want the CDN-flavoured "let the edge pick" UX.

## Variants vs ad-hoc transforms

`image_plug` supports two ways to express a transform: an *ad-hoc* URL with options inline (`/cdn-cgi/image/width=600,fit=cover/cat.jpg`), and a *named variant* stored in the variant store (`/cdn-cgi/image/variant=thumb/cat.jpg`, where `thumb` is a `%Image.Plug.Variant{}` registered in advance).

Both cache the same way: each unique URL is a unique cache entry. But variants give you a layer of indirection that's worth using when you have a fixed set of transform recipes:

* **One name, multiple URL forms.** A `thumb` variant in the store is reachable from every provider's URL grammar without recomputing.

* **Centralised tuning.** Adjusting the `thumb` variant's pipeline (e.g. raising quality from 80 to 85) is one update in one place; ad-hoc URLs require finding and rewriting every reference.

* **Predictable cache hit rates.** A small set of variants means a small set of cache entries per source, so cache fill is fast and eviction is rare. Ad-hoc URLs proliferate with whatever your callers ask for.

The variant model maps cleanly to Cloudflare Images' "Variants" feature — both are name-based aliases for stored pipelines, and both let CDN consumers reference a transform without needing to know its parameters.

For the long tail of one-off transforms (responsive images at 16 sizes, e.g.), ad-hoc URLs win because predefined variants would explode in count. Use variants for the "site furniture" transforms (avatars, thumbnails, cover images) and ad-hoc for everything else.

## Operational concerns

A few things worth knowing before pointing real traffic at this:

* **Cold-cache stampede.** When a popular URL is first requested by N concurrent clients, all N hit your origin if the CDN doesn't coalesce. CloudFront, Fastly, and Cloudflare all coalesce by default (it's called "request collapsing"). nginx requires `proxy_cache_lock on`. Without coalescing, your origin gets hammered on every cold cache.

* **`max_pixels`.** `Image.Plug.init/1` accepts `:max_pixels` (default 25 million). Requests asking for more pixels than that fail fast, before libvips allocates the buffer. Tune it to whatever your hosting tier can comfortably encode without OOM-ing.

* **`request_timeout`.** Per-request budget (default 10 seconds). Very large sources or expensive ops (full segmentation, large rotations) can exceed this; the request fails with a timeout error and the client sees the configured `:on_error` response. If your CDN has a shorter idle timeout than this, set the two to match.

* **Origin scaling.** A single `image_plug` node serves an unbounded URL space — each unique transformed URL is a one-time cost, then the CDN takes over. Capacity planning is "how many *unique* transform requests per second do I expect during cold-cache periods", not "how many image requests per second total". The latter number is bounded by your CDN's bandwidth, not your origin's.

* **Source resolver back-pressure.** If your source resolver streams from S3 (see [`sources.md`](sources.md)), the `image_plug` worker holds an open connection to S3 for the duration of the decode. Sustained high cold-cache rates can saturate S3 connection pools. Consider pre-warming or using a smaller `max_pixels` to bound per-request memory + connection time.

* **Health checks.** Point the CDN's origin health check at a known-cheap URL (e.g. `/cdn-cgi/image/format=auto/_health.png` against a 32×32 PNG) — not at `/`, which is your app and may take a slow path.

## Related

* [`sources.md`](sources.md) — how `image_plug` resolves source bytes (file, HTTP, S3); the `etag_seed` shape that enables CDN-friendly ETags.
* [`usage.md`](usage.md) — mounting `Image.Plug` in your endpoint or router.
* [`face_aware.md`](face_aware.md) — face detection at the origin; cached at the edge like any other transform.
* `Image.Plug.Cache` — the pure module that computes ETag, `Cache-Control`, and `Vary` headers.
* `Image.Plug.Capabilities` — feature probes (e.g. `avif_write?/0`); tells the deployment what formats this origin can actually produce.
