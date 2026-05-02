defmodule Image.Plug.Pipeline.Ops.Enhance do
  @moduledoc """
  Content-aware automatic enhancement. Maps to imgix's
  `auto=enhance`, Cloudinary's `e_improve` family
  (`e_improve`, `e_auto_brightness`, `e_auto_color`,
  `e_auto_contrast`), and ImageKit's `e-retouch`.

  All four CDNs document this as a black-box ML pipeline; we
  approximate it with a sensible-defaults stack of luminance
  equalisation + mild saturation boost + mild sharpening (see
  `Image.enhance/2`). Results are visually similar to the
  hosted services but not byte-identical.

  No tuneable fields in v0.1 — the defaults from
  `Image.enhance/2` are used directly.
  """

  @type t :: %__MODULE__{}
  defstruct []
end
