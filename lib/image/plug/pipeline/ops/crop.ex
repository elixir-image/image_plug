defmodule Image.Plug.Pipeline.Ops.Crop do
  @moduledoc """
  Crop operation. Extracts a sub-rectangle of the working image.

  Distinct from `Image.Plug.Pipeline.Ops.Trim`, which auto-detects or
  removes a border, and distinct from `Image.Plug.Pipeline.Ops.Resize`'s
  fit modes, which scale-and-fit. `Crop` is an absolute extract of the
  region described by `(x, y, width, height)`.

  Two coordinate systems via `:units`:

  * `:pixels` (default) — `x`, `y`, `width`, `height` are measured in
    pixels of the source image. `(0, 0)` is the top-left corner.

  * `:percent` — all four values are floats in `0.0..100.0`,
    interpreted as percentages of the source image's dimensions. The
    interpreter resolves them against the actual source size at apply
    time, which means the same op can be reused across sources of
    different dimensions.

  ### Used by

  * The IIIF Image API 3.0 provider's `region` URL segment, which
    accepts both `x,y,w,h` (pixels) and `pct:x,y,w,h` (percent) forms.

  ### Canonical order

  Per `Image.Plug.Pipeline.Normaliser`, `Crop` runs after `Trim` /
  `Background` and before `Resize`. The IIIF spec processes operations
  in this same order — `region → size → rotation → quality → format` —
  so a IIIF round-trip preserves intent.
  """

  @type units :: :pixels | :percent
  @type t :: %__MODULE__{
          x: number(),
          y: number(),
          width: number(),
          height: number(),
          units: units()
        }

  defstruct x: 0,
            y: 0,
            width: 0,
            height: 0,
            units: :pixels
end
