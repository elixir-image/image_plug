defmodule Image.Plug.Pipeline.Ops.Draw do
  @moduledoc """
  Overlay/watermark operation. Wraps an ordered list of
  `Image.Plug.Pipeline.Ops.Draw.Layer` structs.

  Layers render in list order; later entries appear on top.
  """

  alias Image.Plug.Pipeline.Ops.Draw.Layer

  @type t :: %__MODULE__{layers: [Layer.t()]}

  defstruct layers: []
end
