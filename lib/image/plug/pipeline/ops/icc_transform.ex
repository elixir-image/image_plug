defmodule Image.Plug.Pipeline.Ops.IccTransform do
  @moduledoc """
  ICC-profile-driven colourspace conversion. Distinct from
  `Ops.Colorspace` (which uses libvips' named-interpretation
  modes); this op invokes `Image.to_colorspace/3` and runs an
  actual profile-based transform.

  Used to map provider parameters that target specific output
  profiles — e.g. Cloudinary's `cs_adobergb` (when wired
  against an Adobe RGB ICC file) and any custom-ICC overlay.

  `:profile` is one of `:srgb` / `:cmyk` / `:p3` (libvips
  built-ins) or a path to an `.icc` file. `:intent` is
  forwarded to `Image.to_colorspace/3` and defaults to
  `:relative`.
  """

  @type intent :: :relative | :perceptual | :saturation | :absolute

  @type t :: %__MODULE__{
          profile: atom() | binary(),
          intent: intent()
        }

  defstruct profile: :srgb,
            intent: :relative
end
