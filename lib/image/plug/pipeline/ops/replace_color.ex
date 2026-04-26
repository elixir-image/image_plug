defmodule Image.Plug.Pipeline.Ops.ReplaceColor do
  @moduledoc """
  Replace one colour in the image with another, with a tolerance.

  Wraps `Image.replace_color/2`. Two source-colour selection modes:

  * **Threshold** — pick all pixels within `:threshold` of `:from`.
    `:from` may be a hex string (`"#ff0000"`), a CSS-name string
    (`"misty_rose"` or `"misty rose"`), an integer in 0..255, an
    RGB three-tuple, or the atom `:auto` (the average of the
    top-left 10×10 region of the image is used; this is `Image`'s
    documented default).

  * **Range** — pick all pixels with channel values between
    `:less_than` and `:greater_than`. When both are set, range mode
    wins over the threshold mode.

  In all modes, matched pixels are replaced with `:to` (defaults to
  `"#000000"`). When `:blend?` is `true`, the replacement blends
  smoothly across the boundary rather than hard-cutting.
  """

  @type color :: String.t() | atom() | non_neg_integer() | [non_neg_integer()]

  @type t :: %__MODULE__{
          to: color(),
          from: color() | :auto,
          threshold: non_neg_integer(),
          less_than: nil | color(),
          greater_than: nil | color(),
          blend?: boolean()
        }

  defstruct to: "#000000",
            from: :auto,
            threshold: 20,
            less_than: nil,
            greater_than: nil,
            blend?: false
end
