defmodule Image.Plug.Pipeline.Ops.Segment do
  @moduledoc """
  Subject-segmentation placeholder operation. Cloudflare's `segment=foreground`
  isolates the subject and replaces the background with transparency.

  The op is currently carried through the pipeline as a no-op so requests
  using `segment=foreground` do not 400. A real implementation will land
  alongside `:image_vision` background-removal wire-up (see `TODO.md`).
  """

  @type kind :: :foreground

  @type t :: %__MODULE__{kind: kind()}

  defstruct kind: :foreground
end
