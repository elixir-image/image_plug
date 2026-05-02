defmodule Image.Plug.Pipeline.Ops.Pixelate do
  @moduledoc """
  Block-style pixelation. `:scale` is the resize factor passed
  to `Image.pixelate/2` — smaller values produce coarser blocks
  (e.g. `0.05` = ~20-pixel blocks on a 400-pixel image). Maps
  to Cloudinary's `e_pixelate[:N]` where `N` is a block size in
  pixels (the provider parser converts `N → scale = 1 / N`).
  """

  @type t :: %__MODULE__{scale: float()}
  defstruct scale: 0.05
end
