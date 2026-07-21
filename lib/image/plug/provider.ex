defmodule Image.Plug.Provider do
  @moduledoc """
  Behaviour for URL-API providers.

  A provider parses an inbound `Plug.Conn` into a canonical
  `Image.Plug.Pipeline` plus an `Image.Plug.Source` reference. It
  may also resolve the request to a named variant lookup or to a
  passthrough that streams the source unchanged.

  Providers are stateless. All configuration is passed in by
  `Image.Plug` as the second argument to `c:parse/2`.
  """

  alias Image.Plug.{Error, Pipeline, Source}

  @typedoc """
  An override applied on top of a resolved variant. The provider
  produces these from per-request options that should win over the
  stored variant's defaults.
  """
  @type override :: {atom(), term()}

  @typedoc """
  The shape returned by `c:parse/2` on success.

  * `{:pipeline, pipeline, source}` — fully-formed pipeline; resolve
    the source and execute.

  * `{:variant, name, overrides, source}` — look up the variant by
    name in the configured `Image.Plug.VariantStore`, then merge
    overrides on top before executing.

  * `{:passthrough, source}` — no transforms. The plug streams the
    source unchanged.

  * `{:info, info_kind, source}` — the request is for a metadata
    document (currently only `:iiif_image_info` for the IIIF Image
    API 3.0 `info.json`). The plug builds the document by reading
    the source's dimensions and serialises as JSON.

  * `:skip` — the request is not addressed to this plug (its URL
    matches none of the provider's recognised shapes). The plug
    returns the connection untouched and un-halted so the host
    application's remaining plugs handle it. This is what makes
    `plug Image.Plug` safe to mount at the root of a Phoenix
    endpoint. Reserve `{:error, ...}` for URLs that clearly *intend*
    an image request but are malformed.
  """
  @type info_kind :: :iiif_image_info

  @type result ::
          {:pipeline, Pipeline.t(), Source.t()}
          | {:variant, name :: String.t(), [override()], Source.t()}
          | {:passthrough, Source.t()}
          | {:info, info_kind(), Source.t()}
          | :skip

  @doc """
  Parses a request into one of the `t:result/0` shapes.

  Implementations must be pure URL/header parsing. They must not fetch
  source bytes or look up variants — those are the responsibilities of
  `Image.Plug.SourceResolver` and `Image.Plug.VariantStore`.

  Implementations must not raise on malformed input; return a tagged
  `Image.Plug.Error` instead.
  """
  @callback parse(Plug.Conn.t(), options :: keyword()) ::
              {:ok, result()} | {:error, Error.t()}
end
