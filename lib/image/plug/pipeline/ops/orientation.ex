defmodule Image.Plug.Pipeline.Ops.Orientation do
  @moduledoc """
  EXIF orientation override. `:value` is an integer in `1..8`
  per the EXIF orientation enumeration; the interpreter calls
  `Image.set_orientation/2` to write the metadata field
  without rotating the underlying pixels. Maps to imgix's
  `or=N`.
  """

  @type t :: %__MODULE__{value: 1..8}
  defstruct value: 1
end
