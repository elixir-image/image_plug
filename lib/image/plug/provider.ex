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
  """
  @type result ::
          {:pipeline, Pipeline.t(), Source.t()}
          | {:variant, name :: String.t(), [override()], Source.t()}
          | {:passthrough, Source.t()}

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
