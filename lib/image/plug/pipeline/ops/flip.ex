defmodule Image.Plug.Pipeline.Ops.Flip do
  @moduledoc """
  Flip operation. Mirrors the working image along one or both axes.
  """

  @type direction :: :horizontal | :vertical | :both
  @type t :: %__MODULE__{direction: direction()}

  @enforce_keys [:direction]
  defstruct [:direction]
end
