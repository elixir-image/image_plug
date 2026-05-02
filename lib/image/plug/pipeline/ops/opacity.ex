defmodule Image.Plug.Pipeline.Ops.Opacity do
  @moduledoc """
  Mid-pipeline alpha multiplier. `:factor` is in `[0.0, 1.0]`;
  `1.0` is a no-op (the normaliser drops the op), `0.0` produces
  a fully transparent image. Maps to Cloudinary's `o_<n>`
  (where `n / 100` is passed) and ImageKit's `e-opacity:<n>`.
  """

  @type t :: %__MODULE__{factor: float()}
  defstruct factor: 1.0
end
