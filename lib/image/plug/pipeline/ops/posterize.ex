defmodule Image.Plug.Pipeline.Ops.Posterize do
  @moduledoc """
  Tonal-quantisation operation. `:levels` in `2..256` is the
  number of distinct values per band. Maps to Cloudinary's
  `e_cartoonify[:level_count]` (`level_count` defaults to `5`).
  """

  @type t :: %__MODULE__{levels: pos_integer()}
  defstruct levels: 5
end
