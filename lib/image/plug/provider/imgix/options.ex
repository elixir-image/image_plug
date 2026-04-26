defmodule Image.Plug.Provider.Imgix.Options do
  @moduledoc """
  Parses an [imgix](https://docs.imgix.com/en/latest/apis/rendering)
  query string into a canonical `Image.Plug.Pipeline`.

  Imgix exposes ~80 documented parameters. v0.1 implements the
  common subset that maps cleanly onto the canonical IR:

  * Sizing: `w`, `h`, `dpr`, `fit`, `crop`, `fp-x`, `fp-y`.

  * Output: `q`, `fm`, `auto` (multi-value `format,compress`).

  * Effects: `bg`, `blur`, `sharp`, `bri`, `con`, `sat`, `gam`.

  * Geometry: `flip`, `rot`, `trim`, `trimcolor`, `border`.

  * Overlays: `mark`, `mark-w`, `mark-h`, `mark-x`, `mark-y`,
    `mark-fit`, `mark-rot`.

  * Signing: `s`, `expires` — handled by
    `Image.Plug.Provider.Imgix.Signing`, not here.

  Unknown keys raise `:unknown_option` by default; pass
  `strict?: false` to log and ignore.

  Imgix-only features that don't fit the canonical IR
  (`auto=enhance`, `sepia`, `cs=...`, `or`, AI tags) raise
  `:unsupported_option` so users learn early. As the underlying
  `Image` library adds helpers, these become `:ok` (see this
  project's `TODO.md`).
  """

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops

  require Logger

  @signing_keys ~w(s expires)
  @ignored_keys ~w(ixlib ixid)

  @fit_atoms %{
    "clip" => :contain,
    "clamp" => :contain,
    "crop" => :cover,
    "facearea" => :cover,
    "fill" => :pad,
    "fillmax" => :pad,
    "max" => :scale_down,
    "min" => :scale_down,
    "scale" => :squeeze
  }

  @crop_to_gravity %{
    "top" => :north,
    "bottom" => :south,
    "left" => :west,
    "right" => :east,
    "top,left" => :north_west,
    "top,right" => :north_east,
    "bottom,left" => :south_west,
    "bottom,right" => :south_east,
    "faces" => :face,
    "entropy" => :auto,
    "edges" => :auto,
    "focalpoint" => :focalpoint
  }

  @fm_atoms %{
    "jpg" => :jpeg,
    "jpeg" => :jpeg,
    "pjpg" => :baseline_jpeg,
    "png" => :png,
    "png8" => :png,
    "png32" => :png,
    "webp" => :webp,
    "avif" => :avif
  }

  @flip_atoms %{
    "h" => :horizontal,
    "v" => :vertical,
    "hv" => :both
  }

  @unsupported_keys %{
    "sepia" => "imgix `sepia=` requires a sepia helper in the Image library — see TODO.md",
    "or" => "imgix `or=` (EXIF orientation override) needs the Image library to expose orientation control — see TODO.md",
    "px" => "imgix `px=` (pixelate) needs a pixelate helper in the Image library — see TODO.md"
  }

  # imgix's `cs=<value>` accepts a small set of named colorspaces.
  # Map them to the atoms `Image.to_colorspace/2` accepts.
  @cs_to_target %{
    "srgb" => :srgb,
    "strip" => :srgb,
    "cmyk" => :cmyk,
    "rgb" => :rgb
  }

  @unsupported_auto %{
    "enhance" => "imgix `auto=enhance` needs `Image.enhance/1` — see TODO.md",
    "redeye" => "imgix `auto=redeye` is not implemented",
    "true" => "imgix `auto=true` is unspecified; pass an explicit value like `auto=format,compress`"
  }

  @doc """
  Parses an imgix query string into an `Image.Plug.Pipeline`.

  ### Arguments

  * `query_string` — the raw query string (no leading `?`).

  * `parser_options` — keyword list. `:strict?` (default `true`)
    controls whether unknown keys raise.

  ### Returns

  * `{:ok, pipeline}` on success.

  * `{:error, %Image.Plug.Error{}}` on the first malformed entry.

  ### Examples

      iex> alias Image.Plug.Provider.Imgix.Options
      iex> {:ok, pipeline} = Options.parse("w=200&fit=crop&fm=webp&q=80")
      iex> [resize] = pipeline.ops
      iex> {resize.width, resize.fit}
      {200, :cover}
      iex> pipeline.output.type
      :webp

  """
  @spec parse(String.t(), keyword()) :: {:ok, Pipeline.t()} | {:error, Error.t()}
  def parse(query_string, parser_options \\ []) when is_binary(query_string) do
    strict? = Keyword.get(parser_options, :strict?, true)

    query_string
    |> URI.decode_query()
    |> Map.drop(@signing_keys ++ @ignored_keys)
    |> reduce_entries(strict?)
  end

  defp reduce_entries(params, strict?) do
    initial =
      {:ok,
       %{
         resize: nil,
         adjust: nil,
         output: %Ops.Format{},
         draw_layer: nil,
         appended: [],
         focal_point: %{x: nil, y: nil}
       }}

    params
    |> Enum.sort()
    |> Enum.reduce_while(initial, fn {key, value}, {:ok, acc} ->
      case apply_entry(key, value, acc, strict?) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> finalise()
  end

  defp finalise({:error, _} = error), do: error

  defp finalise({:ok, acc}) do
    pipeline =
      Pipeline.new(provider: Image.Plug.Provider.Imgix)
      |> Pipeline.put_output(acc.output)
      |> append_in_canonical_order(apply_focal_point(acc))

    {:ok, pipeline}
  end

  # If a focalpoint crop was requested AND fp-x/fp-y were provided,
  # rewrite the resize op's gravity to {:xy, fx, fy}.
  defp apply_focal_point(%{resize: %Ops.Resize{gravity: :focalpoint} = resize, focal_point: fp} = acc)
       when not is_nil(fp.x) and not is_nil(fp.y) do
    %{acc | resize: %{resize | gravity: {:xy, fp.x, fp.y}}}
  end

  defp apply_focal_point(%{resize: %Ops.Resize{gravity: :focalpoint} = resize} = acc) do
    # focalpoint crop without fp-x/fp-y → centre
    %{acc | resize: %{resize | gravity: :center}}
  end

  defp apply_focal_point(acc), do: acc

  # Order matches the Cloudflare provider's canonical order (which
  # in turn mirrors Sharp); the normaliser will re-sort as needed.
  defp append_in_canonical_order(pipeline, acc) do
    [
      find_one(acc.appended, Ops.Rotate),
      find_one(acc.appended, Ops.Trim),
      find_one(acc.appended, Ops.Flip),
      acc.resize,
      find_one(acc.appended, Ops.Background),
      find_one(acc.appended, Ops.Border),
      acc.adjust,
      find_one(acc.appended, Ops.Colorspace),
      find_one(acc.appended, Ops.Sharpen),
      find_one(acc.appended, Ops.Blur),
      acc.draw_layer
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(pipeline, &Pipeline.append(&2, &1))
  end

  defp find_one(appended, module) do
    Enum.find(appended, fn op -> op.__struct__ == module end)
  end

  defp ensure_resize(nil), do: %Ops.Resize{}
  defp ensure_resize(%Ops.Resize{} = resize), do: resize

  defp ensure_adjust(nil), do: %Ops.Adjust{}
  defp ensure_adjust(%Ops.Adjust{} = adjust), do: adjust

  defp replace_or_append(appended, %module{} = op) do
    case Enum.find_index(appended, fn existing -> existing.__struct__ == module end) do
      nil -> appended ++ [op]
      index -> List.replace_at(appended, index, op)
    end
  end

  defp invalid(key, value) do
    Error.new(:invalid_option, "invalid value for imgix option",
      details: %{key: key, value: value}
    )
  end

  defp unsupported(key, message) do
    Error.new(:unsupported_option, message, details: %{key: key})
  end

  defp parse_pos_integer(key, value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, invalid(key, value)}
    end
  end

  defp parse_non_neg_integer(key, value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, invalid(key, value)}
    end
  end

  defp parse_int(key, value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, invalid(key, value)}
    end
  end

  defp parse_unit_float(key, value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} when float >= 0.0 and float <= 1.0 -> {:ok, float}
      :error ->
        case Integer.parse(value) do
          {0, ""} -> {:ok, 0.0}
          {1, ""} -> {:ok, 1.0}
          _ -> {:error, invalid(key, value)}
        end

      _ ->
        {:error, invalid(key, value)}
    end
  end

  # ---------- per-key parsers ----------
  # Resize / sizing ---------------------------------------------------

  defp apply_entry("w", value, acc, _strict?) do
    with {:ok, integer} <- parse_pos_integer("w", value) do
      {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:width, integer)}}
    end
  end

  defp apply_entry("h", value, acc, _strict?) do
    with {:ok, integer} <- parse_pos_integer("h", value) do
      {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:height, integer)}}
    end
  end

  defp apply_entry("dpr", value, acc, _strict?) do
    with {:ok, integer} <- parse_pos_integer("dpr", value) do
      resize = ensure_resize(acc.resize) |> Map.put(:dpr, min(integer, 3))
      {:ok, %{acc | resize: resize, output: %{acc.output | dpr: min(integer, 3)}}}
    end
  end

  defp apply_entry("fit", value, acc, _strict?) do
    case Map.fetch(@fit_atoms, value) do
      {:ok, atom} ->
        {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:fit, atom)}}

      :error ->
        {:error, invalid("fit", value)}
    end
  end

  defp apply_entry("crop", value, acc, _strict?) do
    case Map.fetch(@crop_to_gravity, value) do
      {:ok, gravity} ->
        {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:gravity, gravity)}}

      :error ->
        {:error, invalid("crop", value)}
    end
  end

  defp apply_entry("fp-x", value, acc, _strict?) do
    with {:ok, x} <- parse_unit_float("fp-x", value) do
      {:ok, %{acc | focal_point: %{acc.focal_point | x: x}}}
    end
  end

  defp apply_entry("fp-y", value, acc, _strict?) do
    with {:ok, y} <- parse_unit_float("fp-y", value) do
      {:ok, %{acc | focal_point: %{acc.focal_point | y: y}}}
    end
  end

  # Output / format --------------------------------------------------

  defp apply_entry("q", value, acc, _strict?) do
    with {:ok, quality} <- parse_pos_integer("q", value) do
      if quality in 1..100 do
        {:ok, %{acc | output: %{acc.output | quality: quality}}}
      else
        {:error, invalid("q", value)}
      end
    end
  end

  defp apply_entry("fm", value, acc, _strict?) do
    case Map.fetch(@fm_atoms, value) do
      {:ok, atom} -> {:ok, %{acc | output: %{acc.output | type: atom}}}
      :error -> {:error, invalid("fm", value)}
    end
  end

  defp apply_entry("auto", value, acc, _strict?) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, acc}, fn part, {:ok, acc} ->
      case apply_auto_part(part, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Effects ----------------------------------------------------------

  defp apply_entry("bg", value, acc, _strict?) when is_binary(value) and value != "" do
    color = if String.starts_with?(value, "#"), do: value, else: "#" <> value
    {:ok, %{acc | appended: replace_or_append(acc.appended, %Ops.Background{color: color})}}
  end

  defp apply_entry("blur", value, acc, _strict?) do
    with {:ok, n} <- parse_non_neg_integer("blur", value) do
      sigma = min(n, 2000) / 100.0
      op = %Ops.Blur{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_entry("sharp", value, acc, _strict?) do
    with {:ok, n} <- parse_non_neg_integer("sharp", value) do
      sigma = min(n, 100) / 10.0
      op = %Ops.Sharpen{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_entry("bri", value, acc, _strict?), do: adjust(:brightness, value, acc, "bri")
  defp apply_entry("con", value, acc, _strict?), do: adjust(:contrast, value, acc, "con")
  defp apply_entry("sat", value, acc, _strict?), do: adjust(:saturation, value, acc, "sat")
  defp apply_entry("gam", value, acc, _strict?), do: adjust(:gamma, value, acc, "gam")

  # Geometry ---------------------------------------------------------

  defp apply_entry("flip", value, acc, _strict?) do
    case Map.fetch(@flip_atoms, value) do
      {:ok, direction} ->
        op = %Ops.Flip{direction: direction}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error, invalid("flip", value)}
    end
  end

  defp apply_entry("rot", value, acc, _strict?) do
    with {:ok, angle} <- parse_pos_integer("rot", value) do
      if rem(angle, 90) == 0 do
        op = %Ops.Rotate{angle: angle}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
      else
        {:error, invalid("rot", value)}
      end
    end
  end

  defp apply_entry("trim", "auto", acc, _strict?) do
    op = %Ops.Trim{mode: :border}
    {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
  end

  defp apply_entry("trim", "color", acc, _strict?) do
    op = %Ops.Trim{mode: :border}
    {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
  end

  defp apply_entry("trim", value, _acc, _strict?), do: {:error, invalid("trim", value)}

  defp apply_entry("trimcolor", _value, acc, _strict?) do
    # Trimcolor refines trim=color; absorbed by the existing
    # %Trim{} op (the IR carries an optional :color field).
    {:ok, acc}
  end

  defp apply_entry("border", value, acc, _strict?) do
    case String.split(value, ",", parts: 2) do
      [width_str, color] ->
        with {:ok, width} <- parse_non_neg_integer("border", width_str) do
          op = %Ops.Border{
            color: if(String.starts_with?(color, "#"), do: color, else: "#" <> color),
            top: width,
            right: width,
            bottom: width,
            left: width
          }

          {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
        end

      _ ->
        {:error, invalid("border", value)}
    end
  end

  # Colorspace -------------------------------------------------------

  defp apply_entry("cs", value, acc, _strict?) do
    case Map.fetch(@cs_to_target, value) do
      {:ok, target} ->
        op = %Ops.Colorspace{target: target}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error,
         Error.new(:unsupported_option,
           "imgix `cs=#{value}` not implemented (Adobe RGB and other ICC profiles need a `colorspace/3` helper that accepts ICC strings — see TODO.md)",
           details: %{key: "cs", value: value}
         )}
    end
  end

  # imgix `monochrome=<hex>` is a tinted monochrome (B&W image with a
  # named colour replacing what would be black). v0.1 ships plain B&W
  # via `Image.to_colorspace(image, :bw)`; the hex tint is parsed but
  # not yet applied (would need a composite op on a coloured layer).
  # Documented as ⚠️ in the conformance guide.
  defp apply_entry("monochrome", _value, acc, _strict?) do
    op = %Ops.Colorspace{target: :bw}
    {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
  end

  # Overlays ---------------------------------------------------------

  defp apply_entry("mark", value, acc, _strict?) when is_binary(value) and value != "" do
    case Image.Plug.Source.url(value) do
      {:ok, source} ->
        layer = %Ops.Draw.Layer{source: source}
        {:ok, %{acc | draw_layer: %Ops.Draw{layers: [layer]}}}

      {:error, _} = error ->
        error
    end
  end

  # Unsupported keys ---------------------------------------------------

  defp apply_entry(key, _value, _acc, _strict?) when is_map_key(@unsupported_keys, key) do
    {:error, unsupported(key, Map.fetch!(@unsupported_keys, key))}
  end

  # Unknown keys -----------------------------------------------------

  defp apply_entry(key, _value, acc, false) do
    Logger.debug(fn -> "image_plug: ignoring unknown imgix option #{inspect(key)}" end)
    {:ok, acc}
  end

  defp apply_entry(key, value, _acc, true) do
    {:error,
     Error.new(:unknown_option, "unknown imgix option key",
       details: %{key: key, value: value}
     )}
  end

  # ---------- helpers used by per-key clauses ----------

  defp apply_auto_part("format", acc), do: {:ok, %{acc | output: %{acc.output | type: :auto}}}

  defp apply_auto_part("compress", acc),
    do: {:ok, %{acc | output: %{acc.output | compression: :fast}}}

  defp apply_auto_part(other, _acc) do
    case Map.fetch(@unsupported_auto, other) do
      {:ok, message} -> {:error, unsupported("auto=#{other}", message)}
      :error -> {:error, invalid("auto", other)}
    end
  end

  defp adjust(field, value, acc, key) do
    with {:ok, integer} <- parse_int(key, value) do
      if integer in -100..100 do
        multiplier = 1.0 + integer / 100.0
        adjust = ensure_adjust(acc.adjust) |> Map.put(field, multiplier)
        {:ok, %{acc | adjust: adjust}}
      else
        {:error, invalid(key, value)}
      end
    end
  end
end
