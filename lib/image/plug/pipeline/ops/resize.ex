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
          face_zoom: float()
        }

  defstruct width: nil,
            height: nil,
            fit: :contain,
            gravity: :center,
            upscale?: true,
            dpr: 1,
            face_zoom: 0.0
end
