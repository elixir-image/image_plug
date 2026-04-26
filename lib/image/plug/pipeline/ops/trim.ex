defmodule Image.Plug.Pipeline.Ops.Trim do
  @moduledoc """
  Trim operation. Removes border pixels from the working image.

  Two modes:

  * `:border` — auto-detect a uniform border colour and trim it. The
    optional `:color` field overrides the detected colour; `:threshold`
    controls similarity sensitivity (0..255).

  * `:explicit` — trim a fixed number of pixels from each edge given by
    the `:top`, `:right`, `:bottom`, `:left` fields.

  """

  @type mode :: :border | :explicit
  @type t :: %__MODULE__{
          mode: mode(),
          color: nil | String.t(),
          threshold: non_neg_integer(),
          top: non_neg_integer(),
          right: non_neg_integer(),
          bottom: non_neg_integer(),
          left: non_neg_integer()
        }

  defstruct mode: :border,
            color: nil,
            threshold: 10,
            top: 0,
            right: 0,
            bottom: 0,
            left: 0
end
