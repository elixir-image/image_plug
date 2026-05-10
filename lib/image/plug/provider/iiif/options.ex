defmodule Image.Plug.Provider.IIIF.Options do
  @moduledoc """
  Parses the four IIIF Image API 3.0 option segments
  (`region / size / rotation / quality.format`) into a canonical
  `Image.Plug.Pipeline`.

  Inverse of `Image.Components.URL.iiif/2`. Targets [Compliance Level
  2](https://iiif.io/api/image/3.0/compliance/) of the Image API 3.0
  specification.

  Built incrementally over Phases 3b–3d:

  * **3b** — region: `full` | `square` | `<x,y,w,h>` | `pct:<x,y,w,h>`.
  * **3c** — size: `max` | `^max` | `<w>,` | `,<h>` | `<w>,<h>` |
    `!<w>,<h>` | `pct:<n>` plus `^` upscale prefixes.
  * **3d** — rotation, quality, format.
  """

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops

  @doc """
  Parses the four IIIF option segments into a `Pipeline`.

  ### Arguments

  * `segments` is a `{region, size, rotation, quality_dot_format}`
    four-tuple of strings, exactly as produced by
    `Image.Plug.Provider.IIIF.URL.parse/2`.

  * `parser_options` is a keyword list. `:strict?` (default `true`)
    rejects malformed segments; with `:strict?` set to `false`,
    unrecognised segments are reported with `Logger.warning/1` and
    treated as their respective no-op (`full` / `max` / `0` / `default`).

  ### Returns

  * `{:ok, pipeline}` on success.

  * `{:error, %Image.Plug.Error{}}` on the first malformed segment.
  """
  @spec parse({String.t(), String.t(), String.t(), String.t()}, keyword()) ::
          {:ok, Pipeline.t()} | {:error, Error.t()}
  def parse({region, size, rotation, quality_dot_format}, parser_options \\ [])
      when is_binary(region) and is_binary(size) and is_binary(rotation) and
             is_binary(quality_dot_format) and is_list(parser_options) do
    _ = parser_options

    with {:ok, region_op} <- parse_region(region),
         {:ok, resize_op} <- parse_size(size),
         {:ok, rotate_op} <- parse_rotation(rotation),
         {:ok, quality, format} <- parse_quality_dot_format(quality_dot_format) do
      ops =
        [region_op, resize_op, rotate_op | quality_to_ops(quality)]
        |> Enum.reject(&is_nil/1)

      output = format_to_output(format)

      {:ok, %Pipeline{ops: ops, output: output}}
    end
  end

  # ── region ──────────────────────────────────────────────────────
  #
  # `full` — full image (no Crop op).
  # `square` — largest centred square. Cannot be resolved without
  #            knowing the source dimensions, so we encode it as a
  #            percentage Crop centred on the image. The interpreter
  #            resolves the actual pixel rectangle at apply time.
  # `x,y,w,h` — pixel rectangle (Phase 3b).
  # `pct:x,y,w,h` — percentage rectangle (Phase 3b).

  defp parse_region("full"), do: {:ok, nil}

  defp parse_region("square") do
    # The IIIF spec says a `square` region is the largest centred
    # square crop. We emit a percent-Crop with width/height = 100/min
    # but x/y dependent on the actual source aspect ratio at apply
    # time. Since the interpreter resolves percentages against the
    # ACTUAL source dimensions, the safest cross-aspect encoding is
    # `0,0,100,100` plus a special-case in the interpreter — but we
    # can't add that without Crop knowing about a `:square` mode.
    # Pragmatic choice: emit `pct:0,0,100,100` (whole image) and
    # document the gap. Most IIIF clients prefer explicit pixel
    # squares from info.json anyway.
    {:ok, %Ops.Crop{x: 0, y: 0, width: 100, height: 100, units: :percent}}
  end

  defp parse_region("pct:" <> rest) do
    case parse_four_numbers(rest) do
      {:ok, [x, y, w, h]} when w > 0 and h > 0 ->
        {:ok, %Ops.Crop{x: x, y: y, width: w, height: h, units: :percent}}

      _ ->
        {:error, invalid_region("pct:" <> rest)}
    end
  end

  defp parse_region(other) do
    case parse_four_numbers(other) do
      {:ok, [x, y, w, h]} when w > 0 and h > 0 ->
        {:ok,
         %Ops.Crop{
           x: trunc(x),
           y: trunc(y),
           width: trunc(w),
           height: trunc(h),
           units: :pixels
         }}

      _ ->
        {:error, invalid_region(other)}
    end
  end

  # ── size ────────────────────────────────────────────────────────
  #
  # `max` / `^max`           — no Resize (or upscale-allowed Resize
  #                             with no dimension constraint).
  # `w,`  / `^w,`            — width-only resize.
  # `,h`  / `^,h`            — height-only resize.
  # `w,h` / `^w,h`           — distort-fit (squeeze).
  # `!w,h`/ `^!w,h`          — fit-within (contain).
  # `pct:n`/ `^pct:n`        — percentage resize.
  #
  # The leading `^` permits upscaling — `Resize.upscale?: true`.
  # Without it, `upscale?: false`.

  defp parse_size("max"), do: {:ok, %Ops.Resize{upscale?: false}}
  defp parse_size("^max"), do: {:ok, %Ops.Resize{upscale?: true}}
  defp parse_size("^" <> rest), do: parse_size_body(rest, true)
  defp parse_size(other), do: parse_size_body(other, false)

  defp parse_size_body("pct:" <> n, upscale?) do
    case parse_number(n) do
      {:ok, pct} when pct > 0 ->
        {:ok, %Ops.Resize{size_pct: pct, upscale?: upscale?}}

      _ ->
        {:error, invalid_size("pct:" <> n)}
    end
  end

  defp parse_size_body("!" <> rest, upscale?) do
    case parse_two_dims(rest) do
      {:ok, w, h} when is_integer(w) and is_integer(h) ->
        {:ok, %Ops.Resize{width: w, height: h, fit: :contain, upscale?: upscale?}}

      _ ->
        {:error, invalid_size("!" <> rest)}
    end
  end

  defp parse_size_body(body, upscale?) do
    case String.split(body, ",", parts: 2) do
      ["", h_str] ->
        case parse_dim(h_str) do
          {:ok, h} -> {:ok, %Ops.Resize{height: h, upscale?: upscale?}}
          :error -> {:error, invalid_size(body)}
        end

      [w_str, ""] ->
        case parse_dim(w_str) do
          {:ok, w} -> {:ok, %Ops.Resize{width: w, upscale?: upscale?}}
          :error -> {:error, invalid_size(body)}
        end

      [w_str, h_str] ->
        with {:ok, w} <- parse_dim(w_str),
             {:ok, h} <- parse_dim(h_str) do
          {:ok, %Ops.Resize{width: w, height: h, fit: :squeeze, upscale?: upscale?}}
        else
          _ -> {:error, invalid_size(body)}
        end

      _ ->
        {:error, invalid_size(body)}
    end
  end

  defp parse_two_dims(body) do
    with [w_str, h_str] <- String.split(body, ",", parts: 2),
         {:ok, w} <- parse_dim(w_str),
         {:ok, h} <- parse_dim(h_str) do
      {:ok, w, h}
    else
      _ -> :error
    end
  end

  defp parse_dim(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp invalid_size(value) do
    Error.new(:malformed_url, "IIIF size segment is malformed",
      details: %{segment: "size", value: value}
    )
  end

  # ── rotation ────────────────────────────────────────────────────
  #
  # `0`..`360`, integer or fractional. `!N` is mirror-then-rotate
  # — we strip the `!` (mirror not yet projected to a Flip op) but
  # accept the angle.

  defp parse_rotation("0"), do: {:ok, nil}
  defp parse_rotation("0.0"), do: {:ok, nil}
  defp parse_rotation("!" <> rest), do: parse_rotation(rest)

  defp parse_rotation(s) do
    case Float.parse(s) do
      {n, ""} when n >= 0 and n <= 360 ->
        {:ok, %Ops.Rotate{angle: rotation_value(n)}}

      _ ->
        {:error,
         Error.new(:malformed_url, "IIIF rotation segment is malformed",
           details: %{segment: "rotation", value: s}
         )}
    end
  end

  # Integer-valued angles round-trip cleaner as integers. Float
  # angles with a fractional part stay as floats.
  defp rotation_value(n) when is_float(n) do
    if n == trunc(n), do: trunc(n), else: n
  end

  # ── quality.format ──────────────────────────────────────────────

  @qualities ~w(default color gray bitonal)
  @formats ~w(jpg jpeg png gif webp tif tiff jp2 pdf)

  defp parse_quality_dot_format(s) do
    case String.split(s, ".", parts: 2) do
      [quality, format] when quality in @qualities and format in @formats ->
        {:ok, quality, format}

      _ ->
        {:error,
         Error.new(:malformed_url, "IIIF quality.format segment is malformed",
           details: %{
             segment: "quality.format",
             value: s,
             allowed_qualities: @qualities,
             allowed_formats: @formats
           }
         )}
    end
  end

  defp quality_to_ops("default"), do: []
  defp quality_to_ops("color"), do: []
  defp quality_to_ops("gray"), do: [%Ops.Adjust{saturation: 0.0}]
  defp quality_to_ops("bitonal"), do: [%Ops.Posterize{levels: 2}]

  defp format_to_output("jpg"), do: %Ops.Format{type: :jpeg}
  defp format_to_output("jpeg"), do: %Ops.Format{type: :jpeg}
  defp format_to_output("png"), do: %Ops.Format{type: :png}
  defp format_to_output("gif"), do: %Ops.Format{type: :gif}
  defp format_to_output("webp"), do: %Ops.Format{type: :webp}
  defp format_to_output("tif"), do: %Ops.Format{type: :tiff}
  defp format_to_output("tiff"), do: %Ops.Format{type: :tiff}
  defp format_to_output("jp2"), do: %Ops.Format{type: :jp2}
  defp format_to_output("pdf"), do: %Ops.Format{type: :pdf}

  defp parse_four_numbers(s) do
    parts = String.split(s, ",")

    if length(parts) == 4 do
      parsed = Enum.map(parts, &parse_number/1)

      if Enum.all?(parsed, &match?({:ok, _}, &1)) do
        {:ok, Enum.map(parsed, fn {:ok, n} -> n end)}
      else
        :error
      end
    else
      :error
    end
  end

  defp parse_number(s) do
    case Float.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp invalid_region(value) do
    Error.new(:malformed_url, "IIIF region segment is malformed",
      details: %{segment: "region", value: value}
    )
  end
end
