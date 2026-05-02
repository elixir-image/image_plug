defmodule Image.Plug.Pipeline.Ops.DropShadow do
  @moduledoc """
  Drop-shadow operation. The shadow is the source's alpha
  silhouette, blurred, tinted, scaled by `:opacity`, and
  composited beneath the original at `(:dx, :dy)`. Maps to
  ImageKit's `e-shadow=...` parameter family.

  `:color` is normalised to a 3-element `[r, g, b]` 0..255 list
  by the provider parser.
  """

  @type t :: %__MODULE__{
          color: [non_neg_integer()],
          opacity: float(),
          sigma: float(),
          dx: integer(),
          dy: integer()
        }

  defstruct color: [0, 0, 0],
            opacity: 0.5,
            sigma: 5.0,
            dx: 0,
            dy: 10
end
