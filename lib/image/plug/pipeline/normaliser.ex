defmodule Image.Plug.Pipeline.Normaliser do
  @moduledoc """
  Reorders, folds, and validates a pipeline so that two requests with
  the same semantic effect produce identical fingerprints — and so
  that order-sensitive libvips operations land in a position where
  they actually work.

  ### Canonical operation order

  Mirrors the order
  [Sharp](https://github.com/lovell/sharp/blob/main/src/pipeline.cc)
  applies operations internally (Sharp wraps the same libvips
  primitives this library uses). The order encodes years of
  experience with libvips' constraints — most importantly that
  resize must run early enough to benefit from libvips'
  shrink-on-load fast path, and that operations like blur, sharpen,
  and modulate must run in a specific bracket around resize.

  The ordering this module enforces:

  1. `%Trim{}` — trim has to run before resize so the resize sees
     only the meaningful pixels.

  2. `%Background{}` — flatten alpha against the chosen background
     before any colour-shifting op runs.

  3. `%Resize{}` — runs as early as possible so libvips can
     shrink-on-load.

  4. `%Rotate{}` and `%Flip{}` — Cloudflare's rotate is free-angle
     and runs post-resize.

  5. `%Border{}` — embedded after resize because it grows the canvas.

  6. `%Adjust{}` — Sharp's "modulate" stage. Runs after geometry
     so the new pixels participate in tone shifts.

  7. `%Colorspace{}` — runs after `%Adjust{}` (whose multipliers
     expect RGB) and before `%ReplaceColor{}` (whose chroma-key
     match operates on the post-conversion bytes).

  8. `%ReplaceColor{}` — colour-substitution. Runs after Adjust so
     tone shifts on the source colour have already settled, and
     before the sigma-based ops so blur/sharpen operate on the
     post-replace pixels.

  9. `%Blur{}` — Sharp explicitly runs blur before sharpen.

  10. `%Sharpen{}`.

  11. `%Draw{}` — composite layers go on top of the finished base.

  12. `%Pipeline.Ops.Segment{}` — placeholder; ordered last for now.

  ### Cardinality

  These ops must appear at most once per pipeline. The provider's
  options parser already de-duplicates per request, but the
  normaliser is the source of truth so any future programmatic
  pipeline-builder gets the same guarantee:

  * `Resize`, `Trim`, `Flip`, `Rotate`, `Background`, `Border`,
    `Adjust`, `Colorspace`, `ReplaceColor`, `Sharpen`, `Blur`,
    `Segment`.

  `Draw` may appear at most once but holds an arbitrary list of
  layers internally, so multiple overlay requests collapse onto
  layers of one Draw op.

  ### No-op folding

  Drops ops whose fields make them semantically inert:

  * `%Resize{width: nil, height: nil}`

  * `%Rotate{angle: 0}`

  * `%Flip{direction: nil}`

  * `%Adjust{}` with every multiplier `1.0`

  * `%Sharpen{sigma: 0}`, `%Blur{sigma: 0}`

  * `%Border{}` with every side `0`

  * `%Trim{mode: :explicit}` with every side `0`

  ### Idempotence

  `normalise(normalise(p)) == normalise(p)` for every input.

  ### Errors

  Returns `{:error, %Image.Plug.Error{tag: :invalid_option}}` when
  the pipeline contains more than one of an op kind that must be
  unique.
  """

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops

  # The canonical position of each op kind. Lower = earlier in the
  # pipeline. The interpreter is a straight reduce; this list is the
  # only place that knows about ordering.
  @order [
    # Metadata override comes first — `Image.set_orientation/2`
    # only mutates the EXIF tag and doesn't touch pixels, so its
    # position relative to other ops is irrelevant; placing it
    # first keeps the pipeline trace readable.
    {Ops.Orientation, 5},
    {Ops.Trim, 10},
    {Ops.Background, 20},
    {Ops.Resize, 30},
    {Ops.Rotate, 40},
    {Ops.Flip, 50},
    {Ops.Border, 60},
    {Ops.Adjust, 70},
    # Enhance subsumes brightness / contrast / saturation
    # tweaks but produces a globally normalised image; place
    # it just after Adjust so user-explicit adjustments still
    # apply on top.
    {Ops.Enhance, 71},
    {Ops.Colorspace, 72},
    # Profile-driven colourspace conversion runs alongside the
    # named-mode Colorspace op (`:srgb` etc).
    {Ops.IccTransform, 72},
    # Single-pass colour transforms after Adjust/Colorspace.
    {Ops.Sepia, 73},
    {Ops.Tint, 74},
    {Ops.ReplaceColor, 75},
    # Pixel-domain effects.
    {Ops.Posterize, 76},
    {Ops.Pixelate, 77},
    {Ops.Blur, 80},
    {Ops.Sharpen, 90},
    {Ops.Draw, 100},
    {Ops.Segment, 110},
    # Mask / silhouette / alpha adjustments come at the end so
    # they see the fully-rendered colour image.
    {Ops.Vignette, 195},
    {Ops.Fade, 200},
    {Ops.Rounded, 210},
    {Ops.DropShadow, 220},
    {Ops.Opacity, 230}
  ]

  @order_map Map.new(@order)

  # Op kinds that must appear at most once per pipeline.
  @single_instance_ops [
    Ops.Orientation,
    Ops.Trim,
    Ops.Background,
    Ops.Resize,
    Ops.Rotate,
    Ops.Flip,
    Ops.Border,
    Ops.Adjust,
    Ops.Enhance,
    Ops.Colorspace,
    Ops.IccTransform,
    Ops.Sepia,
    Ops.Tint,
    Ops.ReplaceColor,
    Ops.Posterize,
    Ops.Pixelate,
    Ops.Blur,
    Ops.Sharpen,
    Ops.Draw,
    Ops.Segment,
    Ops.Vignette,
    Ops.Fade,
    Ops.Rounded,
    Ops.DropShadow,
    Ops.Opacity
  ]

  @doc """
  Normalises a pipeline. See the moduledoc for the rules applied.

  ### Arguments

  * `pipeline` is an `Image.Plug.Pipeline` struct.

  ### Returns

  * `{:ok, pipeline}` on success.

  * `{:error, %Image.Plug.Error{tag: :invalid_option}}` on a
    cardinality violation.

  ### Examples

      iex> alias Image.Plug.Pipeline
      iex> alias Image.Plug.Pipeline.Ops.{Resize, Rotate, Sharpen}
      iex> p =
      ...>   Pipeline.new()
      ...>   |> Pipeline.append(%Sharpen{sigma: 1.0})
      ...>   |> Pipeline.append(%Resize{width: 200})
      ...>   |> Pipeline.append(%Rotate{angle: 90})
      iex> {:ok, normalised} = Image.Plug.Pipeline.Normaliser.normalise(p)
      iex> Enum.map(normalised.ops, & &1.__struct__)
      [Image.Plug.Pipeline.Ops.Resize,
       Image.Plug.Pipeline.Ops.Rotate,
       Image.Plug.Pipeline.Ops.Sharpen]

  """
  @spec normalise(Pipeline.t()) :: {:ok, Pipeline.t()} | {:error, Error.t()}
  def normalise(%Pipeline{} = pipeline) do
    with {:ok, ops} <- normalise_ops(pipeline.ops) do
      {:ok, %{pipeline | ops: ops}}
    end
  end

  defp normalise_ops(ops) do
    ops = Enum.reject(ops, &noop?/1)

    case validate_cardinalities(ops) do
      :ok -> {:ok, sort(ops)}
      {:error, _} = error -> error
    end
  end

  defp validate_cardinalities(ops) do
    counts =
      Enum.reduce(ops, %{}, fn op, acc ->
        Map.update(acc, op.__struct__, 1, &(&1 + 1))
      end)

    Enum.reduce_while(@single_instance_ops, :ok, fn module, _acc ->
      case Map.get(counts, module, 0) do
        n when n <= 1 ->
          {:cont, :ok}

        n ->
          {:halt,
           {:error,
            Error.new(:invalid_option, "pipeline contains multiple #{inspect(module)} ops",
              details: %{op: module, count: n}
            )}}
      end
    end)
  end

  # Stable sort by canonical position. Ops without a position (which
  # should not happen in practice — every op kind in the IR is in
  # `@order`) sort last, after every documented op.
  defp sort(ops) do
    Enum.sort_by(ops, fn op ->
      Map.get(@order_map, op.__struct__, 999)
    end)
  end

  defp noop?(%Ops.Resize{width: nil, height: nil}), do: true
  defp noop?(%Ops.Rotate{angle: angle}) when angle == 0 or angle == +0.0, do: true
  defp noop?(%Ops.Flip{direction: nil}), do: true
  defp noop?(%Ops.Sharpen{sigma: sigma}) when sigma in [0, +0.0], do: true
  defp noop?(%Ops.Blur{sigma: sigma}) when sigma in [0, +0.0], do: true

  defp noop?(%Ops.Adjust{
         brightness: brightness,
         contrast: contrast,
         gamma: gamma,
         saturation: saturation
       }) do
    [brightness, contrast, gamma, saturation]
    |> Enum.all?(fn multiplier -> multiplier == 1.0 end)
  end

  defp noop?(%Ops.Border{top: 0, right: 0, bottom: 0, left: 0}), do: true
  defp noop?(%Ops.Sepia{strength: s}) when s in [0, +0.0], do: true
  defp noop?(%Ops.Vignette{strength: s}) when s in [0, +0.0], do: true
  defp noop?(%Ops.Opacity{factor: 1.0}), do: true
  defp noop?(%Ops.Posterize{levels: 256}), do: true
  defp noop?(%Ops.Pixelate{scale: s}) when s >= 1.0, do: true

  defp noop?(%Ops.Trim{mode: :explicit, top: 0, right: 0, bottom: 0, left: 0}), do: true

  defp noop?(_), do: false
end
