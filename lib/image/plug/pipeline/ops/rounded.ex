defmodule Image.Plug.Pipeline.Ops.Rounded do
  @moduledoc """
  Rounded-corners mask operation. `:radius` is the corner
  radius in pixels. The atom `:max` produces a fully circular /
  pill-shaped result (radius = half the shorter dimension).
  Maps to Cloudinary's `r_<n>` and `r_max`.
  """

  @type t :: %__MODULE__{radius: pos_integer() | :max}
  defstruct radius: 50
end
