defmodule Image.Plug.Pipeline.Ops.Resize do
  @moduledoc """
  Resize operation. Combines target dimensions, fit mode, gravity (focal
  point for cropping), upscale policy, and DPR (device pixel ratio).

  Either `:width`, `:height`, or both may be set. When only one is set,
  the other is inferred from the source aspect ratio per the chosen
  `:fit` mode.

  `:width` may also be the atom `:auto`, mirroring Cloudflare's
  client-hint-driven sizing. The interpreter resolves it to a concrete
  pixel count from request hints; if no hint is available it falls back
  to the source width.
  """

  @type fit :: :contain | :cover | :crop | :pad | :scale_down | :squeeze

  @type gravity ::
          :auto
          | :face
          | :center
          | :north
          | :south
          | :east
          | :west
          | :north_east
          | :north_west
          | :south_east
          | :south_west
          | {:xy, float(), float()}

  @type t :: %__MODULE__{
          width: nil | :auto | pos_integer(),
          height: nil | pos_integer(),
          fit: fit(),
          gravity: gravity(),
          upscale?: boolean(),
          dpr: pos_integer(),
          face_zoom: float(),
          size_pct: nil | number()
        }

  defstruct width: nil,
            height: nil,
            fit: :contain,
            gravity: :center,
            upscale?: true,
            dpr: 1,
            face_zoom: 0.0,
            # Percentage-of-source resize. When set (a positive number,
            # typically `0.0..100.0`), the interpreter resizes by this
            # percentage instead of using `width`/`height`. Mutually
            # exclusive with `width`/`height`; the IIIF Image API 3.0
            # `pct:N` size form maps to this field, and the URL builder
            # emits `pct:N` when `size_pct` is set and dimensions are
            # nil.
            size_pct: nil
end
