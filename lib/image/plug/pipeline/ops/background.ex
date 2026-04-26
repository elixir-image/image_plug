defmodule Image.Plug.Pipeline.Ops.Background do
  @moduledoc """
  Background fill operation. Flattens any transparency in the working
  image against the given solid colour.

  The colour is parsed lazily by the interpreter — accepted forms are
  `#rgb`, `#rrggbb`, `#rrggbbaa`, CSS colour names, and `rgb()` /
  `rgba()` functional notation.
  """

  @type t :: %__MODULE__{color: String.t()}

  @enforce_keys [:color]
  defstruct [:color]
end
