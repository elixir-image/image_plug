defmodule Image.Plug.Pipeline.Ops.Rotate do
  @moduledoc """
  Rotation operation. Rotates the working image by `angle` degrees
  clockwise.

  Arbitrary angles in `0..360` are accepted by the IR and the
  interpreter — internally this calls `Image.rotate/2` which uses
  libvips' affine transform for non-90° angles. Provider URL parsers
  may impose narrower constraints reflecting their CDN's grammar:

  * **Cloudflare** and **ImageKit** restrict to multiples of 90°
    (the only values their URL grammars accept).

  * **imgix** accepts arbitrary integer degrees.

  * **IIIF Image API 3.0** accepts arbitrary `0..360` (integer or
    fractional), so a `Rotate{angle: 45.5}` round-trips cleanly
    through the IIIF provider.

  An angle of `0` (or `+0.0`) is a no-op and is dropped by
  `Image.Plug.Pipeline.Normaliser`.
  """

  @type t :: %__MODULE__{angle: number()}
  defstruct angle: 0
end
