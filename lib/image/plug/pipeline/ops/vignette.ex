defmodule Image.Plug.Pipeline.Ops.Vignette do
  @moduledoc """
  Radial vignette darkening operation. `:strength` is in
  `[0.0, 1.0]` and matches `Image.vignette/2`'s argument of
  the same name. Maps to Cloudinary's `e_vignette[:N]`
  (`N / 100`, default `0.5`).
  """

  @type t :: %__MODULE__{strength: float()}
  defstruct strength: 0.5
end
