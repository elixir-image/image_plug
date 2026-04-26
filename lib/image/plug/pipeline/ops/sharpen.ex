defmodule Image.Plug.Pipeline.Ops.Sharpen do
  @moduledoc """
  Edge-enhancement operation. Holds a libvips `sigma` value derived
  from the provider's native sharpen parameter (Cloudflare uses 0..10).
  """

  @type t :: %__MODULE__{sigma: float()}
  defstruct sigma: 0.0
end
