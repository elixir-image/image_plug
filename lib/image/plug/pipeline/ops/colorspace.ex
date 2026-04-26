defmodule Image.Plug.Pipeline.Ops.Colorspace do
  @moduledoc """
  Convert the image to a different colorspace.

  Wraps `Image.to_colorspace/2`. Covers two CDN-grammar features
  with one IR primitive:

  * **Monochrome** — `target: :bw` produces a true 1-channel
    grayscale image (smaller bytes than `Adjust{saturation: 0.0}`).
    Used by imgix's `monochrome=<hex>` (the hex tint is not yet
    honoured — v0.1 produces plain B&W).

  * **Colorspace conversion** — any other target. Used by imgix's
    `cs=<space>` and Cloudinary's `cs_<space>`. Common values
    include `:srgb`, `:cmyk`, `:rgb`, `:lab`, `:hsv`. See
    `Image.Interpretation.known_interpretations/0` for the full
    list `Image.to_colorspace/2` accepts.

  ### Pipeline ordering

  The `Image.Plug.Pipeline.Normaliser` slots `Colorspace` between
  `Adjust` (which expects RGB) and `ReplaceColor` (whose colour
  matching operates on the post-conversion bytes). When you don't
  use `Adjust` or `ReplaceColor`, the relative order doesn't matter.
  """

  @type t :: %__MODULE__{
          target: atom()
        }

  defstruct target: :srgb
end
