defmodule Image.Plug.Provider.Cloudflare.Options do
  @moduledoc """
  Parses the comma-separated `<options>` segment of a Cloudflare
  Images URL into a canonical `Image.Plug.Pipeline`.

  Recognised keys (canonical name; aliases in parens):

  * Resize: `width` (`w`), `height` (`h`), `fit`, `gravity` (`g`),
    `dpr`, `zoom` / `face-zoom`.

  * Output: `quality` (`q`), `format` (`f`), `metadata`, `anim`,
    `compression`, `slow-connection-quality` (`scq`).

  * Effects: `background`, `blur`, `sharpen`, `brightness`,
    `contrast`, `gamma`, `saturation`.

  * Geometry: `rotate`, `flip`, `trim`, `border`.

  * Misc: `segment`, `onerror`.

  Aliases normalise to the canonical key before dispatch. Unknown
  keys raise `:unknown_option` by default; pass `strict?: false` to
  log and ignore them. Drawing/overlays via the URL `draw=` grammar
  (`url(...)`, `width`, `height`, `fit`, `gravity`, `opacity`, `top`,
  `left`, `bottom`, `right`, `rotate`, `repeat`, `background`) are
  parsed into `Ops.Draw` layers.
  """

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops

  require Logger

  @aliases %{
    "w" => "width",
    "h" => "height",
    "q" => "quality",
    "f" => "format",
    "g" => "gravity",
    "scq" => "slow-connection-quality",
    "face-zoom" => "zoom"
  }

  @named_quality %{
    "high" => 90,
    "medium-high" => 80,
    "medium-low" => 65,
    "low" => 50
  }

  @fit_atoms %{
    "contain" => :contain,
    "cover" => :cover,
    "crop" => :crop,
    "pad" => :pad,
    "scale-down" => :scale_down,
    "squeeze" => :squeeze
  }

  @format_atoms %{
    "auto" => :auto,
    "avif" => :avif,
    "webp" => :webp,
    "jpeg" => :jpeg,
    "baseline-jpeg" => :baseline_jpeg,
    "png" => :png,
    "json" => :json
  }

  @gravity_atoms %{
    "auto" => :auto,
    "face" => :face,
    "center" => :center,
    "centre" => :center,
    "left" => :west,
    "right" => :east,
    "top" => :north,
    "bottom" => :south,
    "north" => :north,
    "south" => :south,
    "east" => :east,
    "west" => :west,
    "northeast" => :north_east,
    "northwest" => :north_west,
    "southeast" => :south_east,
    "southwest" => :south_west
  }

  @flip_atoms %{
    "h" => :horizontal,
    "v" => :vertical,
    "hv" => :both,
    "vh" => :both
  }

  @metadata_atoms %{
    "copyright" => :copyright,
    "keep" => :keep,
    "none" => :none
  }

  @doc """
  Parses an options string into a `Image.Plug.Pipeline`.

  ### Arguments

  * `options_string` is the comma-separated `<options>` segment from
    the request URL.

  * `parser_options` is a keyword list controlling parsing behaviour.

  ### Options

  * `:strict?` — if `true` (the default), unknown option keys produce
    `{:error, %Image.Plug.Error{tag: :unknown_option}}`. If `false`,
    unknown keys are logged and ignored.

  ### Returns

  * `{:ok, pipeline}` on success.

  * `{:error, %Image.Plug.Error{}}` on the first malformed entry.

  ### Examples

      iex> alias Image.Plug.Provider.Cloudflare.Options
      iex> {:ok, pipeline} = Options.parse("width=200,fit=cover,format=webp", [])
      iex> [resize] = pipeline.ops
      iex> {resize.width, resize.fit}
      {200, :cover}
      iex> pipeline.output.type
      :webp

  """
  @spec parse(String.t(), keyword()) :: {:ok, Pipeline.t()} | {:error, Error.t()}
  def parse(options_string, parser_options \\ []) when is_binary(options_string) do
    strict? = Keyword.get(parser_options, :strict?, true)

    options_string
    |> split_entries()
    |> reduce_entries(strict?)
  end

  defp split_entries(""), do: []

  defp split_entries(options_string) do
    options_string
    |> String.split(",", trim: true)
    |> Enum.map(&split_kv/1)
  end

  defp split_kv(entry) do
    case String.split(entry, "=", parts: 2) do
      [key] -> {String.trim(key), nil}
      [key, value] -> {String.trim(key), String.trim(value)}
    end
  end

  defp reduce_entries(entries, strict?) do
    initial =
      {:ok,
       %{
         resize: nil,
         adjust: nil,
         output: %Ops.Format{},
         on_error: nil,
         appended: []
       }}

    Enum.reduce_while(entries, initial, fn {key, value}, {:ok, acc} ->
      case apply_entry(canonical_key(key), value, acc, strict?) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> finalise()
  end

  defp finalise({:error, _} = error), do: error

  defp finalise({:ok, acc}) do
    pipeline =
      Pipeline.new(provider: Image.Plug.Provider.Cloudflare)
      |> Pipeline.put_output(acc.output)
      |> maybe_put_on_error(acc.on_error)
      |> append_in_canonical_order(acc)

    {:ok, pipeline}
  end

  defp maybe_put_on_error(pipeline, nil), do: pipeline
  defp maybe_put_on_error(pipeline, on_error), do: %{pipeline | on_error: on_error}

  defp canonical_key(key), do: Map.get(@aliases, key, key)

  # Order matches Cloudflare's documented processing order:
  # rotate -> trim -> flip -> resize -> background -> border -> adjust
  # -> sharpen -> blur -> segment.
  defp append_in_canonical_order(pipeline, acc) do
    [
      find_one(acc.appended, Ops.Rotate),
      find_one(acc.appended, Ops.Trim),
      find_one(acc.appended, Ops.Flip),
      acc.resize,
      find_one(acc.appended, Ops.Background),
      find_one(acc.appended, Ops.Border),
      acc.adjust,
      find_one(acc.appended, Ops.Sharpen),
      find_one(acc.appended, Ops.Blur),
      find_one(acc.appended, Ops.Segment),
      find_one(acc.appended, Ops.Draw)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(pipeline, &Pipeline.append(&2, &1))
  end

  defp find_one(appended, module) do
    Enum.find(appended, fn op -> op.__struct__ == module end)
  end

  # Per-key parsers — one clause per option key. Each clause returns
  # `{:ok, acc}` or `{:error, %Error{}}`.

  # Resize family ----------------------------------------------------

  defp apply_entry("width", "auto", acc, _strict?) do
    {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:width, :auto)}}
  end

  defp apply_entry("width", value, acc, _strict?) do
    with {:ok, integer} <- parse_pos_integer("width", value) do
      {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:width, integer)}}
    end
  end

  defp apply_entry("height", value, acc, _strict?) do
    with {:ok, integer} <- parse_pos_integer("height", value) do
      {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:height, integer)}}
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

  defp apply_entry("gravity", value, acc, _strict?) do
    with {:ok, gravity} <- parse_gravity(value) do
      {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:gravity, gravity)}}
    end
  end

  defp apply_entry("dpr", value, acc, _strict?) do
    with {:ok, integer} <- parse_pos_integer("dpr", value) do
      resize = ensure_resize(acc.resize) |> Map.put(:dpr, integer)
      output = %{acc.output | dpr: integer}
      {:ok, %{acc | resize: resize, output: output}}
    end
  end

  defp apply_entry("zoom", value, acc, _strict?) do
    with {:ok, float} <- parse_non_neg_float("zoom", value) do
      {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:face_zoom, float)}}
    end
  end

  # Output / format family -------------------------------------------

  defp apply_entry("quality", value, acc, _strict?) do
    with {:ok, quality} <- parse_quality(value) do
      {:ok, %{acc | output: %{acc.output | quality: quality}}}
    end
  end

  defp apply_entry("format", value, acc, _strict?) do
    case Map.fetch(@format_atoms, value) do
      {:ok, atom} -> {:ok, %{acc | output: %{acc.output | type: atom}}}
      :error -> {:error, invalid("format", value)}
    end
  end

  defp apply_entry("metadata", value, acc, _strict?) do
    case Map.fetch(@metadata_atoms, value) do
      {:ok, atom} -> {:ok, %{acc | output: %{acc.output | metadata: atom}}}
      :error -> {:error, invalid("metadata", value)}
    end
  end

  defp apply_entry("anim", "true", acc, _strict?) do
    {:ok, %{acc | output: %{acc.output | anim?: true}}}
  end

  defp apply_entry("anim", "false", acc, _strict?) do
    {:ok, %{acc | output: %{acc.output | anim?: false}}}
  end

  defp apply_entry("anim", value, _acc, _strict?), do: {:error, invalid("anim", value)}

  defp apply_entry("compression", "fast", acc, _strict?) do
    {:ok, %{acc | output: %{acc.output | compression: :fast}}}
  end

  defp apply_entry("compression", value, _acc, _strict?) do
    {:error, invalid("compression", value)}
  end

  defp apply_entry("slow-connection-quality", value, acc, _strict?) do
    with {:ok, quality} <- parse_quality(value) do
      {:ok, %{acc | output: %{acc.output | scq_quality: quality}}}
    end
  end

  defp apply_entry("onerror", "redirect", acc, _strict?) do
    {:ok, %{acc | on_error: :fallback_to_source}}
  end

  defp apply_entry("onerror", value, _acc, _strict?), do: {:error, invalid("onerror", value)}

  # Effects family ---------------------------------------------------

  defp apply_entry("background", value, acc, _strict?) when is_binary(value) and value != "" do
    op = %Ops.Background{color: value}
    {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
  end

  defp apply_entry("background", value, _acc, _strict?),
    do: {:error, invalid("background", value)}

  defp apply_entry("blur", value, acc, _strict?) do
    with {:ok, float} <- parse_non_neg_float("blur", value) do
      sigma = blur_to_sigma(float)
      op = %Ops.Blur{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_entry("sharpen", value, acc, _strict?) do
    with {:ok, float} <- parse_non_neg_float("sharpen", value) do
      sigma = sharpen_to_sigma(float)
      op = %Ops.Sharpen{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_entry("brightness", value, acc, _strict?) do
    with {:ok, float} <- parse_non_neg_float("brightness", value) do
      adjust = ensure_adjust(acc.adjust) |> Map.put(:brightness, float)
      {:ok, %{acc | adjust: adjust}}
    end
  end

  defp apply_entry("contrast", value, acc, _strict?) do
    with {:ok, float} <- parse_non_neg_float("contrast", value) do
      adjust = ensure_adjust(acc.adjust) |> Map.put(:contrast, float)
      {:ok, %{acc | adjust: adjust}}
    end
  end

  defp apply_entry("gamma", value, acc, _strict?) do
    with {:ok, float} <- parse_non_neg_float("gamma", value) do
      adjust = ensure_adjust(acc.adjust) |> Map.put(:gamma, float)
      {:ok, %{acc | adjust: adjust}}
    end
  end

  defp apply_entry("saturation", value, acc, _strict?) do
    with {:ok, float} <- parse_non_neg_float("saturation", value) do
      adjust = ensure_adjust(acc.adjust) |> Map.put(:saturation, float)
      {:ok, %{acc | adjust: adjust}}
    end
  end

  # Geometry family --------------------------------------------------

  defp apply_entry("rotate", value, acc, _strict?) do
    with {:ok, angle} <- parse_pos_integer("rotate", value) do
      if rem(angle, 90) == 0 do
        op = %Ops.Rotate{angle: angle}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
      else
        {:error, invalid("rotate", value)}
      end
    end
  end

  defp apply_entry("flip", value, acc, _strict?) do
    case Map.fetch(@flip_atoms, value) do
      {:ok, direction} ->
        op = %Ops.Flip{direction: direction}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error, invalid("flip", value)}
    end
  end

  defp apply_entry("trim", value, acc, _strict?) do
    with {:ok, op} <- parse_trim(value) do
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_entry("border", value, acc, _strict?) do
    with {:ok, op} <- parse_border(value) do
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_entry("segment", "foreground", acc, _strict?) do
    op = %Ops.Segment{kind: :foreground}
    {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
  end

  defp apply_entry("segment", value, _acc, _strict?), do: {:error, invalid("segment", value)}

  defp apply_entry("draw", value, acc, _strict?) when is_binary(value) do
    with {:ok, layer} <- parse_draw_layer(value) do
      {:ok, %{acc | appended: append_draw_layer(acc.appended, layer)}}
    end
  end

  defp apply_entry("draw", value, _acc, _strict?), do: {:error, invalid("draw", value)}

  # Unknown keys -----------------------------------------------------

  defp apply_entry(key, _value, acc, false) do
    Logger.debug(fn -> "image_plug: ignoring unknown Cloudflare option #{inspect(key)}" end)
    {:ok, acc}
  end

  defp apply_entry(key, value, _acc, true) do
    {:error,
     Error.new(:unknown_option, "unknown Cloudflare option key",
       details: %{key: key, value: value}
     )}
  end

  defp invalid(key, value) do
    Error.new(:invalid_option, "invalid value for Cloudflare option",
      details: %{key: key, value: value}
    )
  end

  defp parse_pos_integer(key, value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, invalid(key, value)}
    end
  end

  defp parse_pos_integer(key, value), do: {:error, invalid(key, value)}

  defp parse_non_neg_integer(key, value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, invalid(key, value)}
    end
  end

  defp parse_non_neg_integer(key, value), do: {:error, invalid(key, value)}

  defp parse_non_neg_float(key, value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} when float >= 0.0 ->
        {:ok, float}

      :error ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 0 -> {:ok, integer / 1}
          _ -> {:error, invalid(key, value)}
        end
    end
  end

  defp parse_non_neg_float(key, value), do: {:error, invalid(key, value)}

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

  defp parse_quality(value) do
    case Map.fetch(@named_quality, value) do
      {:ok, integer} ->
        {:ok, integer}

      :error ->
        with {:ok, integer} <- parse_pos_integer("quality", value) do
          if integer in 1..100 do
            {:ok, integer}
          else
            {:error, invalid("quality", value)}
          end
        end
    end
  end

  defp parse_gravity(value) do
    case Map.fetch(@gravity_atoms, value) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        parse_xy_gravity(value)
    end
  end

  defp parse_xy_gravity(value) do
    with [x_str, y_str] <- String.split(value, "x", parts: 2),
         {:ok, x} <- parse_unit_float(x_str),
         {:ok, y} <- parse_unit_float(y_str),
         true <- x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0 do
      {:ok, {:xy, x, y}}
    else
      _ -> {:error, invalid("gravity", value)}
    end
  end

  defp parse_unit_float(value) do
    case Float.parse(value) do
      {float, ""} ->
        {:ok, float}

      _ ->
        case Integer.parse(value) do
          {integer, ""} -> {:ok, integer / 1}
          _ -> :error
        end
    end
  end

  # `blur=N` where N is 0..250 maps to a libvips sigma. Cloudflare's
  # exact mapping is not documented; we use the same proportional
  # mapping the Sharp project uses (sigma = N / 2) clipped to [0, 100].
  defp blur_to_sigma(value) when value <= 0, do: 0.0
  defp blur_to_sigma(value) when value > 250, do: 125.0
  defp blur_to_sigma(value), do: value / 2.0

  # `sharpen=N` where N is 0..10 maps to a libvips sigma. We use the
  # documented Cloudflare-friendly mapping sigma = N (sharpen=1 is the
  # baseline value Cloudflare recommends for downscaled images).
  defp sharpen_to_sigma(value) when value <= 0, do: 0.0
  defp sharpen_to_sigma(value) when value > 10, do: 10.0
  defp sharpen_to_sigma(value), do: value / 1.0

  # `trim=border` triggers auto-detect; otherwise expect
  # `trim=top;right;bottom;left`.
  defp parse_trim("border"), do: {:ok, %Ops.Trim{mode: :border}}

  defp parse_trim(value) when is_binary(value) do
    with [t, r, b, l] <- String.split(value, ";"),
         {:ok, top} <- parse_non_neg_integer("trim", t),
         {:ok, right} <- parse_non_neg_integer("trim", r),
         {:ok, bottom} <- parse_non_neg_integer("trim", b),
         {:ok, left} <- parse_non_neg_integer("trim", l) do
      {:ok, %Ops.Trim{mode: :explicit, top: top, right: right, bottom: bottom, left: left}}
    else
      _ -> {:error, invalid("trim", value)}
    end
  end

  defp parse_trim(value), do: {:error, invalid("trim", value)}

  # `border=color=#hex;width=N` or per-side: `border=color=#hex;top=N;...`.
  defp parse_border(value) when is_binary(value) do
    parts =
      value
      |> String.split(";", trim: true)
      |> Enum.map(&split_kv/1)
      |> Map.new()

    color = Map.get(parts, "color", "#000000")

    case Map.get(parts, "width") do
      nil ->
        with {:ok, top} <- border_side(parts, "top"),
             {:ok, right} <- border_side(parts, "right"),
             {:ok, bottom} <- border_side(parts, "bottom"),
             {:ok, left} <- border_side(parts, "left") do
          {:ok, %Ops.Border{color: color, top: top, right: right, bottom: bottom, left: left}}
        end

      width_value ->
        with {:ok, width} <- parse_non_neg_integer("border", width_value) do
          {:ok, %Ops.Border{color: color, top: width, right: width, bottom: width, left: width}}
        end
    end
  end

  defp parse_border(value), do: {:error, invalid("border", value)}

  defp border_side(parts, side) do
    case Map.get(parts, side) do
      nil -> {:ok, 0}
      value -> parse_non_neg_integer("border", value)
    end
  end

  # ---------- draw= sub-grammar ----------
  #
  # `draw=url(<absolute-url>);width=N;height=N;fit=...;gravity=...;
  #         opacity=0.5;repeat=true|x|y;top=N;right=N;bottom=N;left=N;
  #         background=#hex;rotate=90`
  #
  # The first sub-entry must be `url(<absolute-url>)`. Remaining
  # sub-entries are `key=value` pairs separated by `;`.

  @draw_url_re ~r/^url\((?<url>[^)]+)\)$/

  defp parse_draw_layer(value) do
    parts = String.split(value, ";", trim: true)

    with {:ok, url, rest} <- take_draw_url(parts),
         {:ok, source} <- Image.Plug.Source.url(url),
         {:ok, fields} <- parse_draw_fields(rest) do
      build_draw_layer(source, fields)
    end
  end

  defp take_draw_url([first | rest]) when is_binary(first) do
    case Regex.named_captures(@draw_url_re, first) do
      %{"url" => url} -> {:ok, url, rest}
      _ -> {:error, invalid("draw", "missing url(...)")}
    end
  end

  defp take_draw_url([]), do: {:error, invalid("draw", "empty")}

  defp parse_draw_fields(parts) do
    Enum.reduce_while(parts, {:ok, %{}}, fn entry, {:ok, acc} ->
      case String.split(entry, "=", parts: 2) do
        [k, v] -> {:cont, {:ok, Map.put(acc, k, v)}}
        _ -> {:halt, {:error, invalid("draw", entry)}}
      end
    end)
  end

  defp build_draw_layer(source, fields) do
    with {:ok, width} <- optional_pos_int(fields, "width"),
         {:ok, height} <- optional_pos_int(fields, "height"),
         {:ok, fit} <- optional_atom(fields, "fit", @fit_atoms, :contain),
         {:ok, gravity} <- optional_gravity(fields, "gravity", :center),
         {:ok, opacity} <- optional_unit_float(fields, "opacity", 1.0),
         {:ok, repeat} <- optional_repeat(fields, "repeat"),
         {:ok, top} <- optional_pos_int(fields, "top"),
         {:ok, right} <- optional_pos_int(fields, "right"),
         {:ok, bottom} <- optional_pos_int(fields, "bottom"),
         {:ok, left} <- optional_pos_int(fields, "left"),
         {:ok, rotate} <- optional_rotate(fields, "rotate"),
         :ok <- validate_position(top, bottom, left, right) do
      background = Map.get(fields, "background")

      position =
        if Enum.any?([top, bottom, left, right], &(&1 != nil)) do
          {:offset, [top: top, right: right, bottom: bottom, left: left]}
        else
          nil
        end

      {:ok,
       %Ops.Draw.Layer{
         source: source,
         width: width,
         height: height,
         fit: fit,
         gravity: gravity,
         opacity: opacity,
         repeat: repeat,
         position: position,
         background: background,
         rotate: rotate
       }}
    end
  end

  defp optional_pos_int(fields, key) do
    case Map.fetch(fields, key) do
      :error -> {:ok, nil}
      {:ok, value} -> parse_pos_integer("draw.#{key}", value)
    end
  end

  defp optional_atom(fields, key, atoms_map, default) do
    case Map.fetch(fields, key) do
      :error ->
        {:ok, default}

      {:ok, value} ->
        case Map.fetch(atoms_map, value) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, invalid("draw.#{key}", value)}
        end
    end
  end

  defp optional_gravity(fields, key, default) do
    case Map.fetch(fields, key) do
      :error -> {:ok, default}
      {:ok, value} -> parse_gravity(value)
    end
  end

  defp optional_unit_float(fields, key, default) do
    case Map.fetch(fields, key) do
      :error ->
        {:ok, default}

      {:ok, value} ->
        case parse_unit_float(value) do
          {:ok, float} when float >= 0.0 and float <= 1.0 -> {:ok, float}
          _ -> {:error, invalid("draw.#{key}", value)}
        end
    end
  end

  defp optional_repeat(fields, key) do
    case Map.fetch(fields, key) do
      :error -> {:ok, false}
      {:ok, "true"} -> {:ok, true}
      {:ok, "false"} -> {:ok, false}
      {:ok, "x"} -> {:ok, :x}
      {:ok, "y"} -> {:ok, :y}
      {:ok, value} -> {:error, invalid("draw.#{key}", value)}
    end
  end

  defp optional_rotate(fields, key) do
    case Map.fetch(fields, key) do
      :error ->
        {:ok, 0}

      {:ok, value} ->
        with {:ok, angle} <- parse_pos_integer("draw.#{key}", value) do
          if angle in [90, 180, 270] do
            {:ok, angle}
          else
            {:error, invalid("draw.#{key}", value)}
          end
        end
    end
  end

  defp validate_position(top, bottom, _left, _right)
       when not is_nil(top) and not is_nil(bottom) do
    {:error, invalid("draw", "top and bottom may not both be set")}
  end

  defp validate_position(_top, _bottom, left, right)
       when not is_nil(left) and not is_nil(right) do
    {:error, invalid("draw", "left and right may not both be set")}
  end

  defp validate_position(_top, _bottom, _left, _right), do: :ok

  defp append_draw_layer(appended, %Ops.Draw.Layer{} = layer) do
    case Enum.find_index(appended, fn op -> op.__struct__ == Ops.Draw end) do
      nil ->
        appended ++ [%Ops.Draw{layers: [layer]}]

      index ->
        existing = Enum.at(appended, index)
        List.replace_at(appended, index, %{existing | layers: existing.layers ++ [layer]})
    end
  end
end
