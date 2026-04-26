defmodule Image.Plug.SourceResolver do
  @moduledoc """
  Behaviour for source resolvers.

  A resolver turns a `t:Image.Plug.Source.t/0` into an open
  `Vix.Vips.Image` plus a small bag of metadata used for HTTP cache
  headers (`content_type`, `etag_seed`, optionally `last_modified` and
  `byte_size`).

  A resolver typically handles one `Image.Plug.Source` kind. The
  default `Image.Plug.SourceResolver.Composite` dispatches by kind to
  a configured set of per-kind resolvers.
  """

  alias Image.Plug.{Error, Source}

  @typedoc """
  Metadata about the resolved source. The plug uses these values to
  build cache headers and to fingerprint the response for ETag
  computation.

  * `:content_type` — the MIME type of the source bytes.

  * `:etag_seed` — any stable per-source binary. `Image.Plug.Cache`
    hashes this together with the pipeline fingerprint to compute the
    response ETag.

  * `:last_modified` — optional `DateTime` to emit as `Last-Modified`.

  * `:byte_size` — optional integer; informational.

  * `:cache_control` — optional `Cache-Control` directive to forward
    on the response.

  * `:immutable?` — if `true`, the cache layer may add `immutable`.
  """
  @type meta :: %{
          required(:content_type) => String.t(),
          required(:etag_seed) => binary(),
          optional(:last_modified) => DateTime.t(),
          optional(:byte_size) => non_neg_integer(),
          optional(:cache_control) => String.t(),
          optional(:immutable?) => boolean()
        }

  @doc """
  Loads the source bytes referenced by `source` and opens them as a
  `Vix.Vips.Image`.

  Returns the open image plus a `t:meta/0` map.
  """
  @callback load(Source.t(), options :: keyword()) ::
              {:ok, Vix.Vips.Image.t(), meta()} | {:error, Error.t()}
end
