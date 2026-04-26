defmodule Image.Plug.Provider.ImageKit.Options do
  @moduledoc """
  Parses an [ImageKit transform string](https://imagekit.io/docs/transformations)
  into a canonical `Image.Plug.Pipeline`.

  ImageKit's transform vocabulary is medium-sized (~50 keys). v0.1
  implements the common subset that maps cleanly onto the canonical
  IR:

  * Sizing: `w`, `h`, `dpr`, `c` / `cm` (crop mode), `fo` (focus =
    gravity), `x` / `y` (focal point — derived together with
    `fo-custom` or `fo-xy_center`).

  * Output: `q`, `f`.

  * Effects: `bg` (background), `e-blur`, `e-sharpen`, `e-contrast`,
    `e-grayscale`, `e-usm` (unsharp mask).

  * Geometry: `rt` (rotate, multiples of 90), `b` (border
    `b-<W>-<color>`).

  * Overlays: `oi` (overlay-image base form).

  Multiple chained transform stages (`tr:w-200:rt-90`) are flattened
  to a single comma-joined list by the URL recogniser. The canonical
  IR doesn't model chained transforms in v0.1, so order-dependent
  multi-stage recipes collapse to last-write-wins. Documented in
  `guides/image_kit_conformance.md`.

  ImageKit-only features that don't fit the canonical IR
  (`e-shadow`, `e-gradient`, AI tags) raise `:unsupported_option`.
  """

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops

  require Logger

  # ImageKit `c-` / `cm-` modes → canonical fit + (optional) gravity hint.
  @c_to_fit %{
    "maintain_ratio" => :contain,
    "force" => :squeeze,
    "at_least" => :scale_down,
    "at_max" => :scale_down,
    "at_max_enlarge" => :contain,
    "extract" => :crop,
    "pad_extract" => :pad,
    "pad_resize" => :pad
  }

  @fo_to_gravity %{
    "center" => :center,
    "centre" => :center,
    "top" => :north,
    "bottom" => :south,
    "left" => :west,
    "right" => :east,
    "top_left" => :north_west,
    "top_right" => :north_east,
    "bottom_left" => :south_west,
    "bottom_right" => :south_east,
    "auto" => :auto,
    "face" => :face,
    "custom" => :focalpoint,
    "xy_center" => :focalpoint
  }

  @f_to_atom %{
    "jpg" => :jpeg,
    "jpeg" => :jpeg,
    "png" => :png,
    "webp" => :webp,
    "avif" => :avif,
    "auto" => :auto
  }

  @unsupported_effects %{
    "shadow" =>
      "imagekit `e-shadow` needs a drop-shadow helper in the Image library — see TODO.md",
    "gradient" =>
      "imagekit `e-gradient` needs a gradient overlay helper in the Image library — see TODO.md",
    "removedotbg" =>
      "imagekit `e-removedotbg` is a third-party AI background-removal call; not implemented",
    "bgremove" =>
      "imagekit `e-bgremove` is an AI background-removal call; not implemented",
    "changebg" =>
      "imagekit `e-changebg` is a generative-AI call; not implemented",
    "edit" => "imagekit `e-edit` is a generative-AI call; not implemented",
    "retouch" =>
      "imagekit `e-retouch` needs an enhance helper in the Image library — see TODO.md",
    "upscale" =>
      "imagekit `e-upscale` is a model-driven super-resolution call; not implemented"
  }

  @unsupported_keys %{
    "ot" => "imagekit overlay-text (`ot-`) is not implemented in v0.1",
    "obg" => "imagekit overlay-background (`obg-`) is not implemented in v0.1",
    "lo" => "imagekit lossless mode (`lo-`) is not modelled by the encoder yet",
    "pr" => "imagekit progressive flag (`pr-`) is not modelled by the encoder yet",
    "cp" => "imagekit chroma subsampling (`cp-`) is not modelled by the encoder yet",
    "t" => "imagekit named transformation (`t-`) is a server-side alias not modelled by the IR",
    "ar" => "imagekit aspect-ratio shortcut (`ar-`) is not implemented in v0.1",
    "z" => "imagekit zoom (`z-`) is not implemented in v0.1"
  }

  @doc """
  Parses an ImageKit transform string into an `Image.Plug.Pipeline`.

  ### Arguments

  * `transform_string` — the comma-joined transform string emitted
    by `Image.Plug.Provider.ImageKit.URL` (multiple stages already
    flattened to one comma-separated list).

  * `parser_options` — keyword list. `:strict?` (default `true`)
    controls whether unknown keys raise.

  ### Returns

  * `{:ok, pipeline}` on success.

  * `{:error, %Image.Plug.Error{}}` on the first malformed entry.

  ### Examples

      iex> alias Image.Plug.Provider.ImageKit.Options
      iex> {:ok, pipeline} = Options.parse("w-200,c-extract,f-webp,q-80")
      iex> [resize] = pipeline.ops
      iex> {resize.width, resize.fit}
      {200, :crop}
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

  # An entry is `<prefix>-<value>` where prefix is a short token.
  # `e-<name>[-<value>]` may also appear without a value
  # (`e-grayscale`).
  defp parse_entry(entry) do
    case String.split(entry, "-", parts: 2) do
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
      Pipeline.new(provider: Image.Plug.Provider.ImageKit)
      |> Pipeline.put_output(acc.output)
      |> append_in_canonical_order(apply_focal_point(acc))

    {:ok, pipeline}
  end

  defp apply_focal_point(
         %{resize: %Ops.Resize{gravity: :focalpoint} = resize, focal_point: fp} = acc
       )
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
    Error.new(:invalid_option, "invalid value for imagekit option",
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

  defp apply_entry("c", value, acc, _strict?), do: apply_crop_mode(value, acc)
  defp apply_entry("cm", value, acc, _strict?), do: apply_crop_mode(value, acc)

  defp apply_entry("fo", value, acc, _strict?) do
    case Map.fetch(@fo_to_gravity, value) do
      {:ok, gravity} ->
        {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:gravity, gravity)}}

      :error ->
        {:error, invalid("fo", value)}
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
    with {:ok, quality} <- parse_pos_integer("q", value) do
      if quality in 1..100 do
        {:ok, %{acc | output: %{acc.output | quality: quality}}}
      else
        {:error, invalid("q", value)}
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

  defp apply_entry("bg", value, acc, _strict?) when is_binary(value) and value != "" do
    color = if String.starts_with?(value, "#"), do: value, else: "#" <> value
    {:ok, %{acc | appended: replace_or_append(acc.appended, %Ops.Background{color: color})}}
  end

  defp apply_entry("e", value, acc, _strict?) when is_binary(value) do
    case String.split(value, "-", parts: 2) do
      [name] -> apply_effect(name, "", acc)
      [name, sub_value] -> apply_effect(name, sub_value, acc)
    end
  end

  # Geometry ---------------------------------------------------------

  defp apply_entry("rt", value, acc, _strict?) do
    with {:ok, angle} <- parse_int("rt", value) do
      cond do
        rem(angle, 90) == 0 ->
          op = %Ops.Rotate{angle: rem(angle, 360)}
          {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}

        true ->
          {:error, invalid("rt", value)}
      end
    end
  end

  defp apply_entry("b", value, acc, _strict?) do
    # Either `b-<W>-<color>` (which our split-on-first-`-` lands as
    # `value = "<W>-<color>"`) or `b-<W>_<color>` (the underscore
    # form ImageKit also accepts).
    parts =
      cond do
        String.contains?(value, "_") -> String.split(value, "_", parts: 2)
        String.contains?(value, "-") -> String.split(value, "-", parts: 2)
        true -> [value]
      end

    case parts do
      [width_str, color] ->
        with {:ok, width} <- parse_non_neg_integer("b", width_str) do
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
        {:error, invalid("b", value)}
    end
  end

  # Overlays ---------------------------------------------------------

  defp apply_entry("oi", value, acc, _strict?) when is_binary(value) and value != "" do
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
    Logger.debug(fn -> "image_plug: ignoring unknown imagekit option #{inspect(key)}" end)
    {:ok, acc}
  end

  defp apply_entry(key, value, _acc, true) do
    {:error,
     Error.new(:unknown_option, "unknown imagekit option key",
       details: %{key: key, value: value}
     )}
  end

  # ---------- helpers ----------

  defp apply_crop_mode(value, acc) do
    case Map.fetch(@c_to_fit, value) do
      {:ok, fit} ->
        {:ok, %{acc | resize: ensure_resize(acc.resize) |> Map.put(:fit, fit)}}

      :error ->
        {:error, invalid("c", value)}
    end
  end

  defp apply_effect("blur", "", acc), do: apply_effect("blur", "100", acc)

  defp apply_effect("blur", value, acc) do
    with {:ok, n} <- parse_non_neg_integer("e-blur", value) do
      sigma = min(n, 2000) / 100.0
      op = %Ops.Blur{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_effect("sharpen", "", acc), do: apply_effect("sharpen", "100", acc)

  defp apply_effect("sharpen", value, acc) do
    with {:ok, n} <- parse_non_neg_integer("e-sharpen", value) do
      sigma = min(n, 100) / 10.0
      op = %Ops.Sharpen{sigma: sigma}
      {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
    end
  end

  defp apply_effect("usm", value, acc) do
    # Unsharp mask: usm-<radius>-<sigma>-<amount>-<threshold>.
    # We only honour the sigma-equivalent (second component); the
    # rest tweak the kernel and aren't modelled by the IR.
    case String.split(value, "-") do
      [_radius, sigma_str | _] ->
        with {:ok, n} <- parse_non_neg_integer("e-usm", sigma_str) do
          sigma = min(n, 100) / 10.0
          op = %Ops.Sharpen{sigma: sigma}
          {:ok, %{acc | appended: replace_or_append(acc.appended, op)}}
        end

      _ ->
        # Bare `e-usm` with no parameters → default unsharp.
        {:ok, %{acc | appended: replace_or_append(acc.appended, %Ops.Sharpen{sigma: 1.0})}}
    end
  end

  defp apply_effect("contrast", _value, acc) do
    # ImageKit's `e-contrast` is a single boolean toggle (auto-contrast
    # on the input). Approximate by setting Adjust contrast to 1.1
    # (a mild boost). Not exact; documented as ⚠️ in the conformance
    # guide.
    adjust = ensure_adjust(acc.adjust) |> Map.put(:contrast, 1.1)
    {:ok, %{acc | adjust: adjust}}
  end

  defp apply_effect(grayscale, _, acc) when grayscale in ~w(grayscale greyscale) do
    adjust = ensure_adjust(acc.adjust) |> Map.put(:saturation, 0.0)
    {:ok, %{acc | adjust: adjust}}
  end

  defp apply_effect(name, _value, _acc) when is_map_key(@unsupported_effects, name) do
    {:error, unsupported("e-#{name}", Map.fetch!(@unsupported_effects, name))}
  end

  defp apply_effect(name, value, _acc) do
    {:error,
     Error.new(:unknown_option, "unknown imagekit effect",
       details: %{key: "e-#{name}", value: value}
     )}
  end
end
