defmodule Image.Plug.Pipeline.Ops.Rotate do
  @moduledoc """
  Rotation operation. Rotates the working image by `angle` degrees
  clockwise.

  An angle of `0` is a no-op and is dropped by
  `Image.Plug.Pipeline.Normaliser`.
  """

  @type t :: %__MODULE__{angle: number()}
  defstruct angle: 0
end
