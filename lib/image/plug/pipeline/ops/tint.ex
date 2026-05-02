defmodule Image.Plug.Pipeline.Ops.Tint do
  @moduledoc """
  Single-colour tinted-monochrome operation.

  The image is desaturated and the resulting luminance is scaled
  by the requested tint colour: white pixels become the tint
  colour, black pixels remain black. Maps to imgix's
  `monochrome=<hex>` and ImageKit's `e-monochrome=<hex>`.

  `:color` is normalised to a 3-element `[r, g, b]` 0..255 list
  by the provider parser.
  """

  @type t :: %__MODULE__{color: [non_neg_integer()]}
  defstruct color: [128, 128, 128]
end
