defmodule Image.Plug.Pipeline.Ops.Adjust do
  @moduledoc """
  Tonal/colour adjustment operation. A consolidated bag of multiplier
  fields so that adjacent adjustments fold into one op during
  normalisation.

  All four fields are multipliers on the unmodified channel value. A
  value of `1.0` is a no-op; the normaliser drops the field if every
  multiplier is `1.0`.
  """

  @type t :: %__MODULE__{
          brightness: float(),
          contrast: float(),
          gamma: float(),
          saturation: float()
        }

  defstruct brightness: 1.0,
            contrast: 1.0,
            gamma: 1.0,
            saturation: 1.0
end
