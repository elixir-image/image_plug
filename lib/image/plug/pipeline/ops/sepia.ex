defmodule Image.Plug.Pipeline.Ops.Sepia do
  @moduledoc """
  Sepia tone operation. `:strength` is a `[0.0, 1.0]` blend
  factor between the identity (`0.0`) and the full sepia matrix
  (`1.0`). Maps to imgix's `sepia=N` (`N / 100`) and Cloudinary's
  `e_sepia[:N]` (`N / 100`, default full sepia).
  """

  @type t :: %__MODULE__{strength: float()}
  defstruct strength: 1.0
end
