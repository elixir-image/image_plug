defmodule Image.Plug.SourceResolver.HTTP do
  @moduledoc """
  Source resolver that streams images from `http(s)://` URLs.

  Decoding is streaming-friendly: the body flows from the socket
  into libvips chunk-by-chunk via `Image.from_req_stream/2`, which
  uses `Req.get/2` with `into: :self` and feeds bytes into
  `Vix.Vips.Image.new_from_enum/1`.

  ### Configuration

  * `:allowed_hosts` (required) — list of hostname strings the
    resolver will fetch from. Hosts not on the list are rejected
    with `:invalid_option`. Pass `:any` to disable the allow-list
    (only sensible when this resolver sits behind a host-supplied
    auth/auditing layer).

  * `:timeout` — milliseconds to wait between chunks. Defaults to
    `5_000` (the `Image.from_req_stream/2` default).

  ### Limitations (v0.1)

  * The streaming decode path does not surface response headers to
    the caller, so the resolver cannot populate `:last_modified` or
    forward an upstream `ETag`. The `etag_seed` is derived from the
    request URL itself, which gives a stable per-URL ETag without a
    second pass over the body. A future milestone may switch to a
    two-stage HEAD-then-GET when freshness signals are required.

  * Response body size is bounded by whatever limits the configured
    `Req` request honours; we do not impose an additional cap in
    this resolver.

  * Requires the optional `:req` dependency. If `Req` is not loaded
    the resolver returns `:not_implemented` at request time.
  """

  @behaviour Image.Plug.SourceResolver

  alias Image.Plug.{Error, Source}

  @content_types %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp",
    ".avif" => "image/avif",
    ".gif" => "image/gif",
    ".svg" => "image/svg+xml",
    ".tif" => "image/tiff",
    ".tiff" => "image/tiff",
    ".heic" => "image/heic"
  }

  @impl Image.Plug.SourceResolver
  def load(%Source{kind: :url, ref: url}, options) when is_binary(url) do
    with :ok <- ensure_req_loaded(),
         :ok <- ensure_host_allowed(url, Keyword.fetch!(options, :allowed_hosts)),
         {:ok, image} <- open_stream(url, options) do
      meta = %{
        content_type: content_type_for(url),
        etag_seed: :crypto.hash(:sha256, url),
        byte_size: 0
      }

      {:ok, image, meta}
    end
  end

  def load(%Source{kind: kind}, _options) do
    {:error,
     Error.new(:invalid_option, "SourceResolver.HTTP only handles :url sources",
       details: %{got_kind: kind}
     )}
  end

  defp ensure_req_loaded do
    if Code.ensure_loaded?(Req) and function_exported?(Image, :from_req_stream, 2) do
      :ok
    else
      {:error,
       Error.new(
         :not_implemented,
         "SourceResolver.HTTP requires the optional :req dependency to be loaded"
       )}
    end
  end

  defp ensure_host_allowed(_url, :any), do: :ok

  defp ensure_host_allowed(url, allowed_hosts) when is_list(allowed_hosts) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if host in allowed_hosts do
          :ok
        else
          {:error,
           Error.new(:invalid_option, "source host is not on the allow-list",
             details: %{host: host, allowed: allowed_hosts}
           )}
        end

      _ ->
        {:error, Error.new(:invalid_option, "could not extract host from URL")}
    end
  end

  defp open_stream(url, options) do
    timeout = Keyword.get(options, :timeout, 5_000)

    case Image.from_req_stream(url, timeout: timeout) do
      {:ok, image} ->
        {:ok, image}

      {:error, reason} ->
        {:error,
         Error.new(:source_fetch_error, "failed to fetch source over HTTP",
           details: %{url: url, reason: inspect(reason)}
         )}
    end
  end

  defp content_type_for(url) do
    ext = url |> URI.parse() |> Map.get(:path, "") |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end
end
