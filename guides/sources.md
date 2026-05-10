# Image sources

This guide describes how `image_plug` resolves a source reference (the path / URL / hosted-asset-id parsed out of an incoming request) into bytes that libvips can decode. It covers the default file resolver, the bundled HTTP resolver, the `Composite` dispatcher that lets one mount serve all three kinds, and how to write your own — with a worked S3 example.

## The model

A request reaching `image_plug` carries an opaque source reference. The provider URL parser turns that reference into a [`%Image.Plug.Source{}`](`Image.Plug.Source`) struct with one of three `kind`s:

* `:path` — an absolute path string like `"/cat.jpg"`. Comes from URLs like `/cdn-cgi/image/width=600/cat.jpg`.

* `:url` — an absolute `http(s)://` URL. Comes from URLs like `/cdn-cgi/image/width=600/https%3A%2F%2Fexample.com%2Fcat.jpg`.

* `:hosted` — a `{account_hash, image_id}` tuple. Comes from URLs like `/<account>/<image-id>/<variant>` (the Cloudflare hosted form).

A `Image.Plug.SourceResolver` consumes one such struct and returns either an open `Vix.Vips.Image` plus a small bag of HTTP-cache metadata, or an `Image.Plug.Error`. Sources never carry image bytes themselves; they are pure references the resolver knows how to look up.

The resolver is configured per-mount via the `:source_resolver` option on `Image.Plug`:

```elixir
forward "/img", Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare, []},
  source_resolver: {Image.Plug.SourceResolver.File, root: "/var/lib/uploads"}
```

The shape is `{ResolverModule, options}` — a module implementing the [`Image.Plug.SourceResolver`](`Image.Plug.SourceResolver`) behaviour and a keyword list passed to its `load/2`.

## The default: serving files from disk

The most common configuration is `Image.Plug.SourceResolver.File`. It maps `:path` sources to files under a configured root directory:

```elixir
forward "/img", Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare, []},
  source_resolver:
    {Image.Plug.SourceResolver.File, root: "/var/lib/image-uploads"}
```

A request to `/img/cdn-cgi/image/width=600/cat.jpg` reads `/var/lib/image-uploads/cat.jpg`, opens it via `Image.open/2`, and streams the transformed result.

### Configuration

* `:root` (required) — absolute path to the directory under which source files live. Must exist at boot time. Symlinks pointing outside the root are rejected at request time. Path traversal (`..` segments) is blocked at two levels: `Image.Plug.Source.path/1` rejects them before the source even reaches the resolver, and the resolver re-validates that the canonical resolved path is still inside the root.

### Choosing the right `:root`

Three patterns are common:

* **Pin to an absolute path.** Recommended for production. Set `root: "/var/lib/uploads"` or `root: System.fetch_env!("UPLOAD_DIR")`. The path lives outside your release tree, survives redeploys, and is straightforward to mount as a Docker volume.

* **`Path.expand("priv/static/uploads")` at boot.** Convenient in development; uploads land in `priv/static/` so `Plug.Static` can also serve them as the original. Fragile in releases — `priv/static/` lives inside the BEAM tree, and depending on how the path is captured (`Application.app_dir(:my_app, ...)` vs. compile-time `__DIR__`) you can get a resolver pointed at a path that doesn't exist at runtime.

* **Read from `Application.get_env/3` at request time.** The most flexible, but `forward/3` evaluates its options at compile time (or at boot, depending on the Phoenix version), so a literal `Application.get_env/3` call inside the `forward` options usually fires too early to see your runtime config. The fix is a thin wrapper plug — see "Configuring the directory at runtime" below.

### Configuring the directory at runtime

When the upload directory comes from an environment variable in `config/runtime.exs`, the literal `Application.get_env/3` call inside `forward` runs before runtime.exs has executed. The fix is a one-screen wrapper plug that resolves the resolver options on every request:

```elixir
defmodule MyAppWeb.RuntimeImagePlug do
  @behaviour Plug

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, options) do
    full_options =
      Keyword.put(
        options,
        :source_resolver,
        {Image.Plug.SourceResolver.File,
         root: Application.fetch_env!(:my_app, :upload_dir)}
      )

    Image.Plug.call(conn, Image.Plug.init(full_options))
  end
end

# router.ex
forward "/img", MyAppWeb.RuntimeImagePlug,
  provider: {Image.Plug.Provider.Cloudflare, []}

# config/runtime.exs
config :my_app, :upload_dir, System.fetch_env!("UPLOAD_DIR")
```

The wrapper resolves `:upload_dir` from app config on every request, which is correct, but the lookup is essentially free (`:persistent_term`-backed). The same pattern is used by `image_playground` to make the upload dir Docker-volume-mountable; see its `lib/image_playground_web/runtime_image_plug.ex`.

## Streaming HTTP sources

`Image.Plug.SourceResolver.HTTP` resolves `:url` sources by streaming bytes from `http(s)://` URLs into libvips chunk-by-chunk:

```elixir
forward "/img", Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare, []},
  source_resolver:
    {Image.Plug.SourceResolver.HTTP, allowed_hosts: ["assets.example.com", "cdn.example.com"]}
```

A request to `/img/cdn-cgi/image/width=600/https%3A%2F%2Fassets.example.com%2Fcat.jpg` issues a streaming GET against the inner URL, hands the response body to `Vix.Vips.Image.new_from_enum/1`, and pipes the encoded output back to the client without ever materialising the full body in BEAM memory.

### Configuration

* `:allowed_hosts` (required) — a list of hostname strings the resolver will fetch from. Hosts not on the list are rejected with `:invalid_option`. Pass `:any` to disable the allow-list (only sensible when this resolver sits behind a host-supplied auth/auditing layer).

* `:timeout` — milliseconds to wait between chunks. Defaults to `5_000`.

The HTTP resolver depends on `:req` (a transitive dep of `image`); add it to your application's deps if it is not already present.

## Serving multiple kinds from one mount: `Composite`

Most production deployments want one URL prefix that handles both file paths and remote URLs (and possibly hosted asset ids). `Image.Plug.SourceResolver.Composite` dispatches by source kind to a configured set of per-kind resolvers:

```elixir
forward "/img", Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare, []},
  source_resolver:
    {Image.Plug.SourceResolver.Composite,
     file:   [root: "/var/lib/uploads"],
     http:   [allowed_hosts: ["assets.example.com"]],
     hosted: {MyApp.AssetResolver, table: :my_assets}}
```

* `:file` — keyword list passed to `Image.Plug.SourceResolver.File`.
* `:http` — keyword list passed to `Image.Plug.SourceResolver.HTTP`.
* `:hosted` — `{module, options}` tuple for the host's hosted-asset resolver (see "Custom resolvers" below).

A kind not configured returns `:invalid_option` at request time, so you can omit any kind you don't intend to serve.

## Custom resolvers

The `Image.Plug.SourceResolver` behaviour has a single callback:

```elixir
@callback load(Source.t(), options :: keyword()) ::
            {:ok, Vix.Vips.Image.t(), meta()} | {:error, Image.Plug.Error.t()}
```

`meta()` is a small map used by the `Image.Plug.Cache` layer to build response cache headers (`ETag`, `Last-Modified`, `Cache-Control`, `Content-Type`) and to fingerprint responses. The minimum required fields are:

* `:content_type` — MIME type of the source bytes.
* `:etag_seed` — any stable per-source binary; `Image.Plug.Cache` hashes this with the pipeline fingerprint to compute the response ETag.

Optional fields: `:last_modified`, `:byte_size`, `:cache_control`, `:immutable?`.

A skeleton resolver:

```elixir
defmodule MyApp.AssetResolver do
  @behaviour Image.Plug.SourceResolver

  alias Image.Plug.{Error, Source}

  @impl Image.Plug.SourceResolver
  def load(%Source{kind: :hosted, ref: {account, image_id}}, options) do
    with {:ok, bytes, meta} <- fetch(account, image_id, options),
         {:ok, image} <- Image.from_binary(bytes) do
      {:ok, image,
       %{
         content_type: meta.content_type,
         etag_seed: meta.etag_seed,
         last_modified: meta.last_modified,
         byte_size: meta.byte_size
       }}
    else
      {:error, :not_found} ->
        {:error, Error.new(:source_not_found, "asset not found",
          details: %{account: account, image_id: image_id})}
    end
  end

  def load(%Source{kind: kind}, _options) do
    {:error, Error.new(:invalid_option, "unsupported source kind",
      details: %{kind: kind})}
  end

  defp fetch(_account, _image_id, _options), do: {:error, :not_found}
end
```

The behaviour does not require a one-resolver-per-kind layout. Composite is a convenience that dispatches by kind, but a custom resolver is free to handle multiple kinds itself, or only one.

## Worked example: an S3 source resolver

A common deployment is uploads stored in S3, pulled on demand for transformation. The minimum viable implementation uses `Req` with `:aws_sigv4` to sign GETs against a bucket:

```elixir
defmodule MyApp.S3Resolver do
  @moduledoc """
  Source resolver that streams images from an S3 bucket.

  Maps `Image.Plug.Source{kind: :path}` onto
  `s3://<bucket>/<region-aware-key>` and streams the GET into
  libvips chunk-by-chunk via `Image.from_req_stream/2`.

  ### Configuration

  * `:bucket` — required; the S3 bucket name.

  * `:region` — required; the bucket's AWS region (e.g. `\"us-east-1\"`).

  * `:credentials` — required; a 0-arity function that returns
    `%{access_key_id: ..., secret_access_key: ..., token: ...}`. The
    indirection lets you plug in `ExAws.Config.new/1` or a refreshing
    IAM role provider without forcing a hard dep here.

  * `:key_prefix` — optional; prepended to the source path before
    looking up the object. Defaults to `\"\"`.

  * `:timeout` — milliseconds between chunks. Defaults to `5_000`.
  """

  @behaviour Image.Plug.SourceResolver

  alias Image.Plug.{Error, Source}

  @impl Image.Plug.SourceResolver
  def load(%Source{kind: :path, ref: "/" <> path}, options) do
    bucket = Keyword.fetch!(options, :bucket)
    region = Keyword.fetch!(options, :region)
    creds_fun = Keyword.fetch!(options, :credentials)
    prefix = Keyword.get(options, :key_prefix, "")
    timeout = Keyword.get(options, :timeout, 5_000)

    key = Path.join(prefix, path)
    url = "https://#{bucket}.s3.#{region}.amazonaws.com/#{URI.encode(key)}"
    creds = creds_fun.()

    aws_sigv4 = [
      access_key_id: creds.access_key_id,
      secret_access_key: creds.secret_access_key,
      token: Map.get(creds, :token),
      service: "s3",
      region: region
    ]

    case Image.from_req_stream(url, aws_sigv4: aws_sigv4, receive_timeout: timeout) do
      {:ok, image} ->
        {:ok, image,
         %{
           content_type: content_type_for(key),
           etag_seed: "s3:#{bucket}/#{key}"
         }}

      {:error, %{status: 404}} ->
        {:error, Error.new(:source_not_found, "S3 object not found",
          details: %{bucket: bucket, key: key})}

      {:error, reason} ->
        {:error, Error.new(:source_not_found, "S3 fetch failed",
          details: %{bucket: bucket, key: key, reason: reason})}
    end
  end

  def load(%Source{kind: kind}, _options) do
    {:error, Error.new(:invalid_option, "S3Resolver only handles :path sources",
      details: %{kind: kind})}
  end

  defp content_type_for(key) do
    case Path.extname(key) do
      ".jpg"  -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png"  -> "image/png"
      ".gif"  -> "image/gif"
      ".webp" -> "image/webp"
      ".avif" -> "image/avif"
      _       -> "application/octet-stream"
    end
  end
end
```

Wire it in:

```elixir
forward "/img", Image.Plug,
  provider: {Image.Plug.Provider.Cloudflare, []},
  source_resolver:
    {MyApp.S3Resolver,
     bucket: "my-app-uploads",
     region: "us-east-1",
     credentials: &ExAws.Config.new/0,
     key_prefix: "originals/"}
```

A request to `/img/cdn-cgi/image/width=600/cat.jpg` now signs and streams `s3://my-app-uploads/originals/cat.jpg` through libvips and returns a 600-wide WebP without ever buffering the source object in memory.

### A few production notes

* **`etag_seed`.** The example above derives the ETag seed from the bucket + key. That gives a stable per-key ETag — fine if the object is immutable. If you mutate objects in place, prefer the upstream S3 ETag (one HEAD before the GET) or the last-modified timestamp.

* **`last_modified`.** A two-stage HEAD-then-GET lets you populate `:last_modified` from the upstream `Last-Modified` header. The skeleton above skips it for simplicity.

* **Caching the credentials provider.** `&ExAws.Config.new/0` resolves on every request — cheap for static credentials but expensive for IAM-role refresh. Wrap with a cached provider in production.

* **S3 vs the CDN edge.** This pattern has `image_plug` doing the transform, with S3 just providing the bytes. If you want S3 to *serve* the transformed image too (rather than `image_plug` re-transforming on every request), put a CDN like CloudFront in front of `image_plug` — the response ETag and `Cache-Control` headers will keep transformed bytes at the edge. See the caching section in the README.

## Related

* `Image.Plug.SourceResolver` — the behaviour.
* `Image.Plug.SourceResolver.File` — file-on-disk resolver.
* `Image.Plug.SourceResolver.HTTP` — streaming-HTTP resolver.
* `Image.Plug.SourceResolver.Composite` — by-kind dispatcher.
* `Image.Plug.Source` — the source-reference struct providers produce.
* `Image.Plug.Cache` — how `:etag_seed` and the pipeline fingerprint combine to produce the response ETag.
