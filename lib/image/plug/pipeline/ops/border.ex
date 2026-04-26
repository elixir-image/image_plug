defmodule Image.Plug.Pipeline.Ops.Border do
  @moduledoc """
  Border operation. Adds a coloured border of the given per-side widths
  around the working image by embedding it in a larger canvas of the
  border colour.
  """

  @type t :: %__MODULE__{
          color: String.t(),
          top: non_neg_integer(),
          right: non_neg_integer(),
          bottom: non_neg_integer(),
          left: non_neg_integer()
        }

  @enforce_keys [:color]
  defstruct color: "#000000",
            top: 0,
            right: 0,
            bottom: 0,
            left: 0
end
