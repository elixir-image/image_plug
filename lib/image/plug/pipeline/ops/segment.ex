defmodule Image.Plug.Pipeline.Ops.Segment do
  @moduledoc """
  Subject-segmentation placeholder operation. Cloudflare's `segment=foreground`
  isolates the subject and replaces the background with transparency.

  M1 carries the op through the pipeline as a no-op so requests using
  `segment=foreground` do not 400. A real implementation arrives in a
  later milestone.
  """

  @type kind :: :foreground

  @type t :: %__MODULE__{kind: kind()}

  defstruct kind: :foreground
end
