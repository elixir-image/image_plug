defmodule Image.Plug.Provider.IIIF.InfoJson do
  @moduledoc """
  Builds the IIIF Image API 3.0 [Image Information document](https://iiif.io/api/image/3.0/#5-image-information)
  (`info.json`) for a given source.

  The info document describes what the server can do with this
  particular image: its full pixel dimensions, the qualities and
  formats it can deliver, the spec features it supports, and the
  compliance level. Clients fetch info.json before issuing any
  image request to learn what URLs they're allowed to construct.

  This module is invoked by `Image.Plug` when an IIIF provider
  recognises an `info.json` request. The provider tags the request
  with `:json` output; the plug routes to `build/2` instead of the
  normal pipeline interpreter.

  ### Compliance

  Targets [IIIF Image API 3.0 Compliance Level 2](https://iiif.io/api/image/3.0/compliance/).
  The advertised `extraFeatures`, `extraQualities`, and `extraFormats`
  reflect what `Image.Plug.Provider.IIIF.Options` can parse and what
  `Image.Plug.Capabilities` confirms libvips can encode.
  """

  alias Image.Plug.Capabilities

  @context "http://iiif.io/api/image/3/context.json"
  @protocol "http://iiif.io/api/image"
  @profile "level2"
  @type_value "ImageService3"

  # Always-supported qualities — the bare minimum any Compliance Level
  # 0 server promises. Additional qualities (`gray`, `bitonal`) are
  # advertised under `extraQualities` based on what we can actually
  # produce.
  @base_qualities ["default", "color"]
  @extra_qualities ["gray", "bitonal"]

  # Always-supported formats per Compliance Level 1+. JPEG is required
  # by Level 0; PNG is the standard alpha-friendly raster. Anything
  # else is advertised under `extraFormats` based on capabilities.
  @base_formats ["jpg"]
  @level_2_formats ["png"]

  # Always-supported features per Compliance Level 2. The full
  # taxonomy lives at https://iiif.io/api/image/3.0/#57-extra-functionality.
  @base_features [
    "baseUriRedirect",
    "canonicalLinkHeader",
    "cors",
    "jsonldMediaType",
    "mirroring",
    "profileLinkHeader",
    "regionByPct",
    "regionByPx",
    "regionSquare",
    "rotationArbitrary",
    "rotationBy90s",
    "sizeByConfinedWh",
    "sizeByH",
    "sizeByPct",
    "sizeByW",
    "sizeByWh",
    "sizeUpscaling"
  ]

  @doc """
  Builds an info.json map for the given source dimensions.

  ### Arguments

  * `id` is the absolute URL the info.json document is served from
    *without* the trailing `/info.json` segment. Per the spec, this
    is the image's canonical identifier URL.

  * `dimensions` is `{width, height}` of the source image, in
    pixels.

  ### Returns

  * A plain Elixir map ready to be serialised with `:json.encode/1`.

  ### Examples

      iex> info = Image.Plug.Provider.IIIF.InfoJson.build(
      ...>   "https://iiif.example.org/iiif/3/cat.jpg",
      ...>   {1024, 768}
      ...> )
      iex> info["@context"]
      "http://iiif.io/api/image/3/context.json"
      iex> info["width"]
      1024
      iex> info["height"]
      768
      iex> info["protocol"]
      "http://iiif.io/api/image"

  """
  @spec build(String.t(), {pos_integer(), pos_integer()}) :: map()
  def build(id, {width, height}) when is_binary(id) and width > 0 and height > 0 do
    %{
      "@context" => @context,
      "id" => id,
      "type" => @type_value,
      "protocol" => @protocol,
      "profile" => @profile,
      "width" => width,
      "height" => height,
      "extraQualities" => available_extra_qualities(),
      "extraFormats" => available_extra_formats(),
      "extraFeatures" => @base_features
    }
  end

  @doc false
  def base_qualities, do: @base_qualities

  @doc false
  def base_formats, do: @base_formats ++ @level_2_formats

  defp available_extra_qualities do
    # Both gray and bitonal are pure pixel-domain transforms libvips
    # can always produce; no capability probe needed.
    @extra_qualities
  end

  defp available_extra_formats do
    # Cull `tif` / `jp2` / `webp` based on what libvips can actually
    # write. Always advertise WebP (libvips bundled support is
    # ubiquitous), gate the rest on capability probes.
    formats =
      ["webp"]
      |> maybe_append("tif", Capabilities.tiff_write?())
      |> maybe_append("jp2", Capabilities.jp2_write?())
      |> maybe_append("avif", Capabilities.avif_write?())

    formats
  end

  defp maybe_append(list, _value, false), do: list
  defp maybe_append(list, value, true), do: list ++ [value]
end
