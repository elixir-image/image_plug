defmodule Image.Plug.Pipeline.Ops.Blur do
  @moduledoc """
  Gaussian blur operation. Holds a libvips `sigma` value derived from
  the provider's native blur parameter (Cloudflare uses 0..250).
  """

  @type t :: %__MODULE__{sigma: float()}
  defstruct sigma: 0.0
end
