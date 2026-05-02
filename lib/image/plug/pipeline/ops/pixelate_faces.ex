defmodule Image.Plug.Pipeline.Ops.PixelateFaces do
  @moduledoc """
  Pixelates only the regions of an image occupied by detected
  faces, leaving the rest of the image untouched. Maps to
  Cloudinary's `e_pixelate_faces[:N]`.

  `:scale` follows the same convention as `Ops.Pixelate` —
  smaller values produce coarser blocks. The interpreter
  delegates to `Image.Plug.FaceAware.pixelate_faces/2`, which
  is gated on the optional `:image_vision` dependency.
  """

  @type t :: %__MODULE__{scale: float()}
  defstruct scale: 0.05
end
