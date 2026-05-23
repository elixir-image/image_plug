defmodule Image.Plug.TestGenerators do
  @moduledoc """
  StreamData generators for every supported Cloudflare option key.

  Each option exposes two generators:

  * `valid_<key>/0` — produces values within the documented range
    that the parser must accept.

  * `invalid_<key>/0` — produces values that the parser must
    reject with `:invalid_option` (or `:unknown_option` for
    unknown keys).

  Use these to build property tests:

      property "width=N produces an image of width N" do
        check all width <- valid_width() do
          ...
        end
      end

  See `Image.Plug.IntegrationCase` for the test-case template
  these generators are designed to plug into.
  """

  import StreamData

  # ----- core resize -----

  def valid_width, do: integer(1..2000)
  def invalid_width, do: one_of([integer(-100..0), constant("foo"), constant("")])

  def valid_height, do: integer(1..2000)
  def invalid_height, do: one_of([integer(-100..0), constant("foo"), constant("")])

  def valid_fit do
    member_of(["contain", "cover", "crop", "pad", "scale-down", "squeeze"])
  end

  def invalid_fit, do: filter(string(:alphanumeric, max_length: 10), &(&1 not in known_fits()))

  def valid_dpr, do: integer(1..3)
  def invalid_dpr, do: one_of([integer(-5..0), constant("auto")])

  # ----- output / format -----

  def valid_format do
    member_of(["auto", "avif", "webp", "jpeg", "baseline-jpeg", "png", "json"])
  end

  def invalid_format do
    filter(string(:alphanumeric, max_length: 6), &(&1 not in known_formats()))
  end

  def valid_quality do
    one_of([integer(1..100), member_of(["high", "medium-high", "medium-low", "low"])])
  end

  def invalid_quality do
    one_of([integer(101..1000), integer(-100..0), constant("very_high"), constant("")])
  end

  def valid_metadata, do: member_of(["copyright", "keep", "none"])

  def invalid_metadata,
    do: filter(string(:alphanumeric, max_length: 8), &(&1 not in known_metadata()))

  def valid_anim, do: member_of(["true", "false"])
  def invalid_anim, do: one_of([constant("yes"), constant(""), constant("1")])

  # ----- effects -----

  # Sharpen accepts 0..10; blur accepts 0..250 per Cloudflare.
  def valid_sharpen, do: integer(0..10)
  def invalid_sharpen, do: one_of([integer(11..1000), constant("max")])

  def valid_blur, do: integer(0..250)
  def invalid_blur, do: one_of([integer(251..10_000), constant("yes")])

  # Brightness/contrast/gamma/saturation are non-negative
  # multipliers. The parser accepts integers and floats.
  def valid_multiplier, do: one_of([integer(0..5), float(min: 0.0, max: 5.0)])
  def invalid_multiplier, do: one_of([float(max: -0.1), constant("up")])

  # ----- geometry -----

  def valid_rotate, do: member_of([90, 180, 270])
  def invalid_rotate, do: filter(integer(1..359), &(&1 not in [90, 180, 270]))

  def valid_flip, do: member_of(["h", "v", "hv"])
  def invalid_flip, do: filter(string(:alphanumeric, max_length: 4), &(&1 not in known_flips()))

  def valid_gravity do
    member_of([
      "auto",
      "face",
      "center",
      "left",
      "right",
      "top",
      "bottom",
      "north",
      "south",
      "east",
      "west",
      "northeast",
      "northwest",
      "southeast",
      "southwest"
    ])
  end

  def invalid_gravity do
    one_of([constant("upleft"), constant("middle"), constant("0.5x"), constant("nope")])
  end

  # ----- composite generators -----

  @doc """
  Picks a random valid `key=value` pair from the supported set.
  Useful for building random options-strings.
  """
  def valid_option_pair do
    one_of([
      map(valid_width(), &{"width", to_string(&1)}),
      map(valid_height(), &{"height", to_string(&1)}),
      map(valid_fit(), &{"fit", &1}),
      map(valid_quality(), &{"quality", to_string(&1)}),
      map(valid_format(), &{"format", &1}),
      map(valid_metadata(), &{"metadata", &1}),
      map(valid_dpr(), &{"dpr", to_string(&1)}),
      map(valid_anim(), &{"anim", &1}),
      map(valid_blur(), &{"blur", to_string(&1)}),
      map(valid_sharpen(), &{"sharpen", to_string(&1)}),
      map(valid_rotate(), &{"rotate", to_string(&1)}),
      map(valid_flip(), &{"flip", &1}),
      map(valid_gravity(), &{"gravity", &1})
    ])
  end

  @doc """
  Random valid options-string of length 1..max.
  """
  def valid_options_string(max \\ 5) do
    list_of(valid_option_pair(), min_length: 1, max_length: max)
    |> map(&dedup_keys/1)
    |> map(&encode_pairs/1)
  end

  defp dedup_keys(pairs) do
    pairs
    |> Enum.reverse()
    |> Enum.uniq_by(fn {k, _} -> k end)
    |> Enum.reverse()
  end

  defp encode_pairs(pairs) do
    pairs |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join(",")
  end

  # ----- vocabularies (also used by invalid generators) -----

  defp known_fits, do: ["contain", "cover", "crop", "pad", "scale-down", "squeeze"]
  defp known_formats, do: ["auto", "avif", "webp", "jpeg", "baseline-jpeg", "png", "json"]
  defp known_metadata, do: ["copyright", "keep", "none"]
  defp known_flips, do: ["h", "v", "hv"]
end
