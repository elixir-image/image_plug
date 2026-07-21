defmodule Image.Plug.Provider.IIIF do
  @moduledoc """
  [IIIF Image API 3.0](https://iiif.io/api/image/3.0/) URL provider.

  Recognises and parses the IIIF Image API URL form into the canonical
  `Image.Plug.Pipeline` IR. Targets [Compliance Level 2](https://iiif.io/api/image/3.0/compliance/),
  the level most production servers implement.

  ### URL form

      <mount>/<endpoint>/<identifier>/<region>/<size>/<rotation>/<quality>.<format>

  Where:

  * `<mount>` is whatever path prefix the plug is `forward`-mounted at
    in the host's router. Stripped before recognition.

  * `<endpoint>` is an optional per-server prefix segment (e.g. `iiif/3`
    for a vanilla deployment, `image` for Wellcome Collection's server).
    Configured via the provider's `:endpoint` option.

  * `<identifier>` is the source asset's identifier — typically a
    filename or content-addressed key. Percent-encoded; `%2F` separates
    sub-paths within the identifier.

  * `<region>` is `full` | `square` | `<x,y,w,h>` | `pct:<x,y,w,h>`.

  * `<size>` is `max` | `^max` | `<w>,` | `,<h>` | `<w>,<h>` |
    `!<w>,<h>` | `pct:<n>` and any of those forms with the `^` upscale
    prefix.

  * `<rotation>` is any number `0..360`, optionally prefixed with `!`
    for mirror-then-rotate. Decimal angles are accepted.

  * `<quality>` is `default` | `color` | `gray` | `bitonal`.

  * `<format>` is `jpg` | `png` | `gif` | `webp` | `tif` | `jp2` | `pdf`.

  Two endpoints are also defined by the spec:

  * `<mount>/<endpoint>/<identifier>/info.json` — the discovery
    document. Handled by `Image.Plug.Provider.IIIF.InfoJson` (Phase 4).

  * `<mount>/<endpoint>/<identifier>` — bare identifier; the spec
    requires a `303 See Other` redirect to the info.json. Currently
    returns `:malformed_url`; the redirect is on the roadmap.

  ### Options

  * `:mount` — string path prefix this plug is mounted under.
    Defaults to `""`. Stripped from `path_info` before parsing.

  * `:endpoint` — additional path segment between mount and
    identifier. Defaults to `"iiif/3"` (matching the IIIF reference
    server convention). Set to `""` for servers that publish at the
    mount root.

  * `:strict?` — if `true` (default), unknown URL segments produce
    an `:malformed_url` error. If `false`, the parser is more
    permissive — useful while migrating older Image API 2.x URLs.

  ### Compliance

  Level 2 of the IIIF Image API 3.0 spec. The full compliance matrix
  ships in `guides/iiif_conformance.md`. Notable deliberate gaps:

  * The `square` region form parses to a centred square crop using
    `Image.Plug.Pipeline.Ops.Crop` with computed pixel coordinates.
    Servers serve images from their own `info.json`; since this
    provider ships its own info doc (Phase 4), the computation is
    self-consistent.

  * The mirror-then-rotate form (`!N`) parses into a `Rotate` op but
    the leading mirror is silently dropped. A `Flip` op for that
    case is on the roadmap.
  """

  @behaviour Image.Plug.Provider

  alias Image.Plug.Provider.IIIF.{Options, URL}

  @impl Image.Plug.Provider
  def parse(%Plug.Conn{} = conn, options) when is_list(options) do
    case URL.parse(conn, Keyword.take(options, [:mount, :endpoint])) do
      :unrecognised ->
        {:ok, :skip}

      {:ok, recognised} ->
        build_result(recognised, options)

      {:error, _reason} = error ->
        error
    end
  end

  defp build_result(%{kind: :info_json, source: source}, _options) do
    # `Image.Plug` reads the source via the configured resolver,
    # extracts width/height, and hands them to
    # `Image.Plug.Provider.IIIF.InfoJson.build/2`.
    {:ok, {:info, :iiif_image_info, source}}
  end

  defp build_result(%{kind: :image, options_segments: segments, source: source}, options) do
    with {:ok, pipeline} <- Options.parse(segments, Keyword.take(options, [:strict?])) do
      result =
        case pipeline.ops do
          [] -> {:passthrough, source}
          _ -> {:pipeline, pipeline, source}
        end

      {:ok, result}
    end
  end
end
