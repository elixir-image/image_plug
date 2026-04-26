defmodule Image.Plug.Pipeline.Ops.Draw.Layer do
  @moduledoc """
  A single overlay layer used by `Image.Plug.Pipeline.Ops.Draw`.

  The interpreter prefers SVG composition: when the layer source
  resolves to (or can be expressed as) SVG, the overlay is rendered via
  `Image.from_svg/2` so it scales without raster artefacts. Bitmap
  sources are decoded, optionally resized, and composited with the
  configured opacity.

  Position is either `nil` (centre) or `{:offset, ...}` with any
  combination of `:top` / `:bottom` and `:left` / `:right` (a side and
  its opposite cannot both be set; the provider rejects that at parse
  time).
  """

  @type fit :: :contain | :cover | :crop | :pad | :scale_down
  @type repeat :: false | true | :x | :y
  @type position :: nil | {:offset, keyword()}

  @type t :: %__MODULE__{
          source: Image.Plug.Source.t(),
          width: nil | pos_integer(),
          height: nil | pos_integer(),
          fit: fit(),
          gravity: Image.Plug.Pipeline.Ops.Resize.gravity(),
          opacity: float(),
          repeat: repeat(),
          position: position(),
          background: nil | String.t(),
          rotate: 0 | 90 | 180 | 270
        }

  @enforce_keys [:source]
  defstruct source: nil,
            width: nil,
            height: nil,
            fit: :contain,
            gravity: :center,
            opacity: 1.0,
            repeat: false,
            position: nil,
            background: nil,
            rotate: 0
end
