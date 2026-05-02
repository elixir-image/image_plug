defmodule Image.Plug.Provider.Cloudinary.Options do
  @moduledoc """
  Parses a [Cloudinary transform string](https://cloudinary.com/documentation/transformation_reference)
  into a canonical `Image.Plug.Pipeline`.

  Cloudinary's transform vocabulary is large (~100+ keys). v0.1
  implements the common subset that maps cleanly onto the canonical
  IR:

  * Sizing: `w_`, `h_`, `dpr_`, `c_` (crop mode), `g_` (gravity),
    `x_` / `y_` (focal point — derived together with `g_xy_center`).

  * Output: `q_`, `f_`.

  * Effects: `b_` (background), `e_blur:`, `e_sharpen:`,
    `e_brightness:`, `e_contrast:`, `e_saturation:`, `e_gamma:`.

  * Geometry: `a_` (rotate, multiples of 90), `e_grayscale` (treated
    as `Adjust{saturation: 0.0}`), `bo_` (border `bo_<W>px_solid_<color>`).

  * Overlays: `l_<public-id>` (single-layer base form).

  Multiple transform stages (`w_200,c_fill/e_blur:300/`) are
  flattened by the URL recogniser into a single comma-joined string;
  this parser then walks them as one set. The canonical IR doesn't
  model chained transforms in v0.1, so order-dependent multi-stage
  recipes (sharpen → resize → sharpen) collapse to last-write-wins.
  This is documented in `guides/cloudinary_conformance.md`.

  Cloudinary-only features that don't fit the canonical IR
  (`e_vignette`, `e_pixelate`, `e_cartoonify`, `e_replace_color`,
  `e_fade`, `cs_srgb`, named transformations `t_<name>`) raise
  `:unsupported_option` so users learn early.
  """

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops

  require Logger

  # Cloudinary `c_` modes → canonical fit + (optional) gravity hint.
  # crop=:crop is preserved as a fit value distinct from :cover so
  # the interpreter can choose absolute-pixel cropping when both
  # width AND height are given.
  @c_to_fit %{
    "scale" => :squeeze,
    "fit" => :contain,
    "limit" => :scale_down,
    "mfit" => :contain,
    "fill" => :cover,
    "lfill" => :cover,
    "crop" => :crop,
    "thumb" => :cover,
    "pad" => :pad,
    "lpad" => :pad,
    "mpad" => :pad,
    "fill_pad" => :pad,
    "imagga_crop" => :cover,
    "imagga_scale" => :squeeze
  }

  @g_to_gravity %{
    "north" => :north,
    "north_east" => :north_east,
    "north_west" => :north_west,
    "south" => :south,
    "south_east" => :south_east,
    "south_west" => :south_west,
    "east" => :east,
    "west" => :west,
    "center" => :center,
    "centre" => :center,
    "face" => :face,
    "faces" => :face,
    "auto" => :auto,
    "auto:subject" => :auto,
    "auto:classic" => :auto,
    "xy_center" => :focalpoint
  }

  @f_to_atom %{
    "jpg" => :jpeg,
    "jpe" => :jpeg,
    "jpeg" => :jpeg,
    "png" => :png,
    "webp" => :webp,
    "avif" => :avif,
    "auto" => :auto
  }

  # Cloudinary's `cs_<value>` accepts a small set of named
  # colorspaces. Map them to the atoms `Image.to_colorspace/2`
  # accepts. `tinysrgb` is Cloudinary-specific (size-optimised
  # sRGB); we map to plain `:srgb` since the tinification is a
  # Cloudinary product layer, not a colorspace.
  @cs_to_target %{
    "srgb" => :srgb,
    "tinysrgb" => :srgb,
    "no_cmyk" => :srgb,
    "cmyk" => :cmyk
  }

  @unsupported_effects %{
    "redeye" => "cloudinary `e_redeye` is not implemented"
  }

  # Cloudinary CSS colour name forms accept underscores between
  # multi-word names (e.g. `misty_rose`) and lowercase hex without a
  # leading `#`. We pass both through verbatim — the Image library's
  # `Image.replace_color/2` accepts hex strings (`"#abcdef"`), CSS
  # names (string or atom), 0..255 integers, and RGB lists.
  defp normalise_replace_color_value("rgb:" <> hex), do: "#" <> hex

  defp normalise_replace_color_value(value) when is_binary(value) do
    cond do
      hex_color?(value) -> "#" <> value
      true -> value
    end
  end

  defp hex_color?(value) when byte_size(value) in [3, 6, 8] do
    String.match?(value, ~r/^[0-9a-fA-F]+$/)
  end

  defp hex_color?(_value), do: false

  # Re-join consecutive `["rgb", "<hex>"]` pairs that an outer
  # colon-split has separated. `["rgb", "abcdef", "50", "rgb", "fedcba"]`
  # → `["rgb:abcdef", "50", "rgb:fedcba"]`.
  defp glue_rgb([]), do: []

  defp glue_rgb(["rgb", hex | rest]) do
    ["rgb:" <> hex | glue_rgb(rest)]
  end

  defp glue_rgb([head | rest]) do
    [head | glue_rgb(rest)]
  end

  @unsupported_keys %{
    "t" => "cloudinary named transformations (`t_<name>`) are server-side aliases not modelled by the IR",
    "u" => "cloudinary underlay `u_` is not implemented in v0.1",
    "if" => "cloudinary conditional transforms (`if_...`) are not implemented in v0.1",
    "vc" => "cloudinary video codec `vc_` is video-only",
    "ac" => "cloudinary audio codec `ac_` is video-only",
    "br" => "cloudinary bitrate `br_` is video-only"
  }

  @doc """
  Parses a Cloudinary transform string into an `Image.Plug.Pipeline`.

  ### Arguments

  * `transform_string` — the comma-joined transform string emitted
    by `Image.Plug.Provider.Cloudinary.URL` (multiple stages are
    pre-flattened to one comma-separated list).

  * `parser_options` — keyword list. `:strict?` (default `true`)
    controls whether unknown keys raise.

  ### Returns

  * `{:ok, pipeline}` on success.

  * `{:error, %Image.Plug.Error{}}` on the first malformed entry.

  ### Examples

      iex> alias Image.Plug.Provider.Cloudinary.Options
      iex> {:ok, pipeline} = Options.parse("w_200,c_fill,f_webp,q_80")
      iex> [resize] = pipeline.ops
      iex> {resize.width, resize.fit}
      {200, :cover}
      iex> pipeline.output.type
      :webp

  """
  @spec parse(String.t(), keyword()) :: {:ok, Pipeline.t()} | {:error, Error.t()}
  def parse(transform_string, parser_options \\ []) when is_binary(transform_string) do
    strict? = Keyword.get(parser_options, :strict?, true)

    transform_string
    |> split_entries()
    |> reduce_entries(strict?)
  end

  defp split_entries(""), do: []

  defp split_entries(string) do
    string
    |> String.split(",", trim: true)
    |> Enum.map(&parse_entry/1)
  end

  # An entry is `<prefix>_<value>` where prefix is a short letter
  # token. `e_<name>[:<value>]` is the only entry that can carry an
  # internal colon.
  defp parse_entry(entry) do
    case String.split(entry, "_", parts: 2) do
      [prefix, value] -> {prefix, value}
      [prefix] -> {prefix, ""}
    end
  end

  defp reduce_entries(entries, strict?) do
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

    entries
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
      Pipeline.new(provider: Image.Plug.Provider.Cloudinary)
      |> Pipeline.put_output(acc.output)
      |> append_in_canonical_order(apply_focal_point(acc))

    {:ok, pipeline}
  end

  defp apply_focal_point(%{resize: %Ops.Resize{gravity: :focalpoint} = resize, focal_point: fp} = acc)
       when not is_nil(fp.x) and not is_nil(fp.y) do
    %{acc | resize: %{resize | gravity: {:xy, fp.x, fp.y}}}
  end

  defp apply_focal_point(%{resize: %Ops.Resize{gravity: :focalpoint} = resize} = acc) do
    %{acc | resize: %{resize | gravity: :center}}
  end

  defp apply_focal_point(acc), do: acc

  defp append_in_canonical_order(pipeline, acc) do
    [
      find_one(acc.appended, Ops.Rotate),
      find_one(acc.appended, Ops.Flip),
      acc.resize,
      find_one(acc.appended, Ops.Background),
      find_one(acc.appended, Ops.Border),
      acc.adjust,
      find_one(acc.appended, Ops.Enhance),
      find_one(acc.appended, Ops.Colorspace),
      find_one(acc.appended, Ops.Sepia),
      find_one(acc.appended, Ops.Tint),
      find_one(acc.appended, Ops.ReplaceColor),
      find_one(acc.appended, Ops.Posterize),
      find_one(acc.appended, Ops.Pixelate),
      find_one(acc.appended, Ops.PixelateFaces),
      find_one(acc.appended, Ops.Sharpen),
      find_one(acc.appended, Ops.Blur),
      find_one(acc.appended, Ops.Vignette),
      find_one(acc.appended, Ops.Fade),
      find_one(acc.appended, Ops.Rounded),
      find_one(acc.appended, Ops.Opacity),
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
    Error.new(:invalid_option, "invalid value for cloudinary option",
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

  # Range-bounded integer parser. Returns `{:ok, n}` or `:error`
  # without wrapping in a typed error so callers can produce
  # context-specific messages.
  defp parse_int_in_range_value(value, range) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> if n in range, do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  defp parse_int_in_range_value(_value, _range), do: :error

  defp parse_unit_float(key, value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} when float >= 0.0 and float <= 1.0 -> {:ok, float}
      _ -> {:error, invalid(key, value)}
    end
  end

  # ---------- per-key parsers ----------
  # Sizing -----------------------------------------------------------

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
      capped = min(integer, 3)
      resize = ensure_resize(acc.resize) |> Map.put(:dpr, capped)
      {:ok, %{acc | resize: resize, output: %{acc.output | dpr: capped}}}
    end
  end

  # `z_<float>` — face-zoom factor, only meaningful with
  # `g_face`. Range `[0.0, 1.0]` matches the IR's
  # `Resize.face_zoom` and the symmetric ImageKit `z-` /
  # Cloudflare `face-zoom=` parsers.
  defp apply_entry("z", value, acc, _strict?) do
    case Float.parse(value) do
      {f, ""} when f >= 0.0 and f <= 1.0 ->
        resize = ensure_resize(acc.resize) |> Map.put(:face_zoom, f)
        {:ok, %{acc | resize: resize}}

      _ ->
        {:error, invalid("z", value)}
    end
  end

  defp apply_entry("c", value, acc, _strict?) do
    case Map.fetch(@c_to_fit, value) do
      {:ok, fit} ->
        {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:fit, fit)}}

      :error ->
        {:error, invalid("c", value)}
    end
  end

  defp apply_entry("g", value, acc, _strict?) do
    case Map.fetch(@g_to_gravity, value) do
      {:ok, gravity} ->
        {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:gravity, gravity)}}

      :error ->
        {:error, invalid("g", value)}
    end
  end

  defp apply_entry("x", value, acc, _strict?) do
    with {:ok, x} <- parse_unit_float("x", value) do
      {:ok, %{acc | focal_point: %{acc.focal_point | x: x}}}
    end
  end

  defp apply_entry("y", value, acc, _strict?) do
    with {:ok, y} <- parse_unit_float("y", value) do
      {:ok, %{acc | focal_point: %{acc.focal_point | y: y}}}
    end
  end

  # Output -----------------------------------------------------------

  defp apply_entry("q", value, acc, _strict?) do
    case value do
      # `q_auto` and `q_auto:eco` etc. are Cloudinary's content-aware
      # quality. The Image library doesn't have an "auto quality"
      # knob; we leave the encoder default (85) in place. The
      # `:compression: :fast` flag is set so the encoder leans on
      # libvips' faster encode path.
      "auto" ->
        {:ok, %{acc | output: %{acc.output | compression: :fast}}}

      "auto:" <> _ ->
        {:ok, %{acc | output: %{acc.output | compression: :fast}}}

      _ ->
        with {:ok, quality} <- parse_pos_integer("q", value) do
          if quality in 1..100 do
            {:ok, %{acc | output: %{acc.output | quality: quality}}}
          else
            {:error, invalid("q", value)}
          end
        end
    end
  end

  defp apply_entry("f", value, acc, _strict?) do
    case Map.fetch(@f_to_atom, value) do
      {:ok, atom} -> {:ok, %{acc | output: %{acc.output | type: atom}}}
      :error -> {:error, invalid("f", value)}
    end
  end

  # Effects ----------------------------------------------------------

  defp apply_entry("b", value, acc, _strict?) when is_binary(value) and value != "" do
    color = normalise_color(value)
    {:ok, %{acc | appended: replace_or_append(acc.appended, %Ops.Background{color: color})}}
  end

  defp apply_entry("e", value, acc, _strict?) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [name] -> apply_effect(name, "", acc)
      [name, sub_value] -> apply_effect(name, sub_value, acc)
    end
  end

  # Geometry ---------------------------------------------------------

  defp apply_entry("a", value, acc, _strict?) do
    with {:ok, angle} <- parse_int("a", value) do
      cond do
        rem(angle, 90) == 0 ->
          op = %Ops.Rotate{angle: rem(angle, 360)}
          {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

        true ->
          {:error, invalid("a", value)}
      end
    end
  end

  defp apply_entry("bo", value, acc, _strict?) do
    # bo_<W>px_solid_<rgb:RRGGBB> or bo_<W>px_solid_<color>
    case String.split(value, "_", parts: 3) do
      [width_str, "solid", color] ->
        width_str = String.trim_trailing(width_str, "px")

        with {:ok, width} <- parse_non_neg_integer("bo", width_str) do
          op = %Ops.Border{
            color: normalise_border_color(color),
            top: width,
            right: width,
            bottom: width,
            left: width
          }

          {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
        end

      _ ->
        {:error, invalid("bo", value)}
    end
  end

  defp apply_entry("fl", "force_strip", acc, _strict?) do
    # Strip metadata is implicit in our encoder (we don't carry it).
    # Recognised so users with `fl_force_strip` in their URLs don't
    # get rejected.
    {:ok, acc}
  end

  defp apply_entry("fl", "preserve_transparency", acc, _strict?), do: {:ok, acc}

  defp apply_entry("fl", "progressive", acc, _strict?) do
    {:ok, %{acc | output: %{acc.output | progressive: true}}}
  end

  defp apply_entry("fl", "lossy", acc, _strict?) do
    {:ok, %{acc | output: %{acc.output | lossy: true}}}
  end

  defp apply_entry("fl", value, _acc, _strict?), do: {:error, invalid("fl", value)}

  # Rounded corners ----------------------------------------------------
  #
  # Cloudinary `r_<n>` — n is the corner radius in pixels.
  # `r_max` produces a fully circular / pill-shaped result.
  defp apply_entry("r", "max", acc, _strict?) do
    op = %Ops.Rounded{radius: :max}
    {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
  end

  defp apply_entry("r", value, acc, _strict?) do
    with {:ok, n} <- parse_pos_integer("r", value) do
      op = %Ops.Rounded{radius: n}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  # Mid-pipeline opacity -----------------------------------------------
  #
  # Cloudinary `o_<n>` — n is a 0..100 opacity percentage.
  defp apply_entry("o", value, acc, _strict?) do
    case parse_int_in_range_value(value, 0..100) do
      {:ok, 100} ->
        {:ok, acc}

      {:ok, percent} ->
        op = %Ops.Opacity{factor: percent / 100}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error, invalid("o", value)}
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
           "cloudinary `cs_#{value}` not implemented. " <>
             "Custom-ICC profiles (Adobe RGB, ProPhoto, etc.) need an `Ops.IccTransform{}` " <>
             "op constructed programmatically with `profile: \"path/to/profile.icc\"` — " <>
             "the parser does not synthesise these from URL strings.",
           details: %{key: "cs", value: value}
         )}
    end
  end

  # Overlays ---------------------------------------------------------

  defp apply_entry("l", value, acc, _strict?) when is_binary(value) and value != "" do
    # Single-public-id overlay. v0.1 treats it as a relative path
    # against the source resolver.
    case Image.Plug.Source.path("/" <> value) do
      {:ok, source} ->
        layer = %Ops.Draw.Layer{source: source}
        {:ok, %{acc | draw_layer: %Ops.Draw{layers: [layer]}}}

      {:error, _} = error ->
        error
    end
  end

  # Unsupported keys -------------------------------------------------

  defp apply_entry(key, _value, _acc, _strict?) when is_map_key(@unsupported_keys, key) do
    {:error, unsupported(key, Map.fetch!(@unsupported_keys, key))}
  end

  # Unknown keys -----------------------------------------------------

  defp apply_entry(key, _value, acc, false) do
    Logger.debug(fn -> "image_plug: ignoring unknown cloudinary option #{inspect(key)}" end)
    {:ok, acc}
  end

  defp apply_entry(key, value, _acc, true) do
    {:error,
     Error.new(:unknown_option, "unknown cloudinary option key",
       details: %{key: key, value: value}
     )}
  end

  # ---------- effect dispatch ----------

  defp apply_effect("blur", "", acc), do: apply_effect("blur", "100", acc)

  defp apply_effect("blur", value, acc) do
    with {:ok, n} <- parse_non_neg_integer("e_blur", value) do
      sigma = min(n, 2000) / 100.0
      op = %Ops.Blur{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_effect("sharpen", "", acc), do: apply_effect("sharpen", "100", acc)

  defp apply_effect("sharpen", value, acc) do
    with {:ok, n} <- parse_non_neg_integer("e_sharpen", value) do
      sigma = min(n, 100) / 10.0
      op = %Ops.Sharpen{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_effect("brightness", value, acc), do: adjust_effect(:brightness, value, acc, "e_brightness")
  defp apply_effect("contrast", value, acc), do: adjust_effect(:contrast, value, acc, "e_contrast")
  defp apply_effect("saturation", value, acc), do: adjust_effect(:saturation, value, acc, "e_saturation")
  defp apply_effect("gamma", value, acc), do: adjust_effect(:gamma, value, acc, "e_gamma")

  defp apply_effect(grayscale, _, acc) when grayscale in ~w(grayscale greyscale) do
    adjust = ensure_adjust(acc.adjust) |> Map.put(:saturation, 0.0)
    {:ok, %{acc | adjust: adjust}}
  end

  # Cloudinary `e_replace_color:<to>[:<tolerance>[:<from>]]`. Default
  # `<from>` is `:auto` (the average of the top-left 10×10 region of
  # the image), default tolerance is 50. Colour values may take the
  # `rgb:RRGGBB` form which contains its own colon — `glue_rgb/1`
  # rejoins those before the per-position split.
  defp apply_effect("replace_color", value, acc) do
    {to, tolerance, from} =
      case glue_rgb(String.split(value, ":")) do
        [to] -> {to, "50", nil}
        [to, tolerance] -> {to, tolerance, nil}
        [to, tolerance, from] -> {to, tolerance, from}
        _ -> {value, "50", nil}
      end

    with {:ok, threshold} <- parse_non_neg_integer("e_replace_color", tolerance) do
      op = %Ops.ReplaceColor{
        to: normalise_replace_color_value(to),
        from: if(is_nil(from), do: :auto, else: normalise_replace_color_value(from)),
        threshold: threshold
      }

      appended =
        case Enum.find_index(acc.appended, fn existing ->
               existing.__struct__ == Ops.ReplaceColor
             end) do
          nil -> acc.appended ++ [op]
          index -> List.replace_at(acc.appended, index, op)
        end

      {:ok, %{acc | appended: appended}}
    end
  end

  # `e_improve` and the `e_auto_*` family map to `Image.enhance/2`,
  # a sensible-defaults stack of luminance equalisation +
  # saturation boost + mild sharpen. Cloudinary's hosted versions
  # are ML-driven; we approximate.
  defp apply_effect(name, _value, acc)
       when name in ~w(improve auto_brightness auto_color auto_contrast) do
    op = %Ops.Enhance{}
    {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
  end

  # `e_vignette[:N]` — N is 0..100 strength percentage. Default
  # is `50` (matches `Image.vignette/2`'s `:strength` default).
  defp apply_effect("vignette", "", acc), do: apply_effect("vignette", "50", acc)

  defp apply_effect("vignette", value, acc) do
    case parse_int_in_range_value(value, 0..100) do
      {:ok, 0} ->
        {:ok, acc}

      {:ok, n} ->
        op = %Ops.Vignette{strength: n / 100}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error, invalid("e_vignette", value)}
    end
  end

  # `e_sepia[:N]` — N is 0..100 strength percentage. Default
  # full sepia when no value is given.
  defp apply_effect("sepia", "", acc), do: apply_effect("sepia", "100", acc)

  defp apply_effect("sepia", value, acc) do
    case parse_int_in_range_value(value, 0..100) do
      {:ok, 0} ->
        {:ok, acc}

      {:ok, n} ->
        op = %Ops.Sepia{strength: n / 100}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error, invalid("e_sepia", value)}
    end
  end

  # `e_pixelate[:N]` — N is the block size in pixels. Default
  # block size 5 when no value is given.
  defp apply_effect("pixelate", "", acc), do: apply_effect("pixelate", "5", acc)

  defp apply_effect("pixelate", value, acc) do
    with {:ok, block_size} <- parse_pos_integer("e_pixelate", value) do
      op = %Ops.Pixelate{scale: 1.0 / block_size}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  # `e_pixelate_faces[:N]` — same block-size convention as
  # `e_pixelate`, but only the regions occupied by detected
  # faces are pixelated. Requires the optional `:image_vision`
  # dependency at runtime; without it the interpreter
  # silently no-ops (returns the source image unchanged).
  defp apply_effect("pixelate_faces", "", acc), do: apply_effect("pixelate_faces", "5", acc)

  defp apply_effect("pixelate_faces", value, acc) do
    with {:ok, block_size} <- parse_pos_integer("e_pixelate_faces", value) do
      op = %Ops.PixelateFaces{scale: 1.0 / block_size}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  # `e_cartoonify[:level_count]` — `level_count` defaults to
  # `5`. We map straight through to `Image.posterize/2`'s
  # tonal-quantisation; Cloudinary's full effect also adds an
  # edge-detect overlay we don't model.
  defp apply_effect("cartoonify", "", acc), do: apply_effect("cartoonify", "5", acc)

  defp apply_effect("cartoonify", value, acc) do
    case parse_int_in_range_value(value, 2..256) do
      {:ok, levels} ->
        op = %Ops.Posterize{levels: levels}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error, invalid("e_cartoonify", value)}
    end
  end

  # `e_fade[:N]` — N is a 0..100 length percentage applied to
  # the bottom edge by default (matches Cloudinary's documented
  # default). Cloudinary's directional flavours
  # (`e_fade_top` etc.) aren't modelled in v0.1.
  defp apply_effect("fade", "", acc), do: apply_effect("fade", "20", acc)

  defp apply_effect("fade", value, acc) do
    case parse_int_in_range_value(value, 0..100) do
      {:ok, 0} ->
        {:ok, acc}

      {:ok, percent} ->
        op = %Ops.Fade{edges: [:bottom], length: percent / 100}
        {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

      :error ->
        {:error, invalid("e_fade", value)}
    end
  end

  defp apply_effect(name, _value, _acc) when is_map_key(@unsupported_effects, name) do
    {:error, unsupported("e_#{name}", Map.fetch!(@unsupported_effects, name))}
  end

  defp apply_effect(name, value, _acc) do
    {:error,
     Error.new(:unknown_option, "unknown cloudinary effect",
       details: %{key: "e_#{name}", value: value}
     )}
  end

  defp adjust_effect(field, value, acc, key) do
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

  # `b_<color>` accepts `rgb:RRGGBB`, `rgb:RRGGBBAA`, `<colorname>`,
  # or `auto:border` etc. We map the common rgb form; everything else
  # is forwarded verbatim to libvips' colour parser via
  # `Image.flatten/2`.
  defp normalise_color("rgb:" <> hex), do: "#" <> hex
  defp normalise_color(other), do: other

  defp normalise_border_color("rgb:" <> hex), do: "#" <> hex
  defp normalise_border_color(other), do: "#" <> other
end
