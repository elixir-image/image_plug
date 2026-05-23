defmodule Image.Plug.FaceAware do
  @moduledoc """
  Face-aware crop, zoom, and pixelation, gated on the optional
  [`:image_vision`](https://hex.pm/packages/image_vision)
  dependency.

  This is the single seam between `image_plug` and
  `Image.FaceDetection`. The interpreter calls
  `available?/0` to decide whether to do face-aware work or
  fall back to today's saliency-based behaviour
  (libvips' `:attention` crop). Without `:image_vision` in
  the consumer's deps, every function in this module returns
  `{:error, :unavailable}` and the interpreter routes around
  it transparently.

  ## Used by

  * `Resize{gravity: :face, face_zoom: ...}` — pre-crops the
    image to the most prominent face plus padding before the
    regular thumbnail resize pass.

  * `PixelateFaces` — detects faces and pixelates only those
    regions, preserving the rest of the image.

  Maps to Cloudflare `face-zoom`, ImageKit `z-`, Cloudinary
  `gravity=face` / `e_pixelate_faces`, and imgix `crop=faces`.
  """

  alias Vix.Vips.Image, as: Vimage

  # `Image.FaceDetection` lives in the optional sibling
  # `:image_vision` library and isn't a declared dep of
  # `image_plug`. The function calls below are guarded at
  # runtime by `Code.ensure_loaded?/1`; tell the compiler to
  # treat them as known so no warnings fire when
  # `:image_vision` is absent at build time.
  @compile {:no_warn_undefined, Image.FaceDetection}

  @doc """
  Returns `true` if `Image.FaceDetection` is loaded — i.e. if
  the consumer added `:image_vision` to their deps.

  Cheap to call; checked on every Resize that asks for
  `gravity: :face`.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Image.FaceDetection)
  end

  @doc """
  Crops the image to the largest detected face, expanded by
  padding derived from `face_zoom`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `face_zoom` is a float in `[0.0, 1.0]`:
    * `0.0` → loose crop with lots of context around the face
      (`padding = 1.0`).
    * `1.0` → tight crop hugging the face bounding box
      (`padding = 0.0`).
    * `0.6` (Cloudflare's default) → moderate zoom
      (`padding = 0.4`).

  ### Returns

  * `{:ok, cropped_image}` on success.

  * `{:error, :no_face}` if no face was detected at the
    default confidence threshold.

  * `{:error, :unavailable}` if `Image.FaceDetection` isn't
    loaded.
  """
  @spec face_crop(Vimage.t(), float()) ::
          {:ok, Vimage.t()} | {:error, :no_face | :unavailable}
  def face_crop(%Vimage{} = image, face_zoom)
      when is_number(face_zoom) and face_zoom >= 0.0 and face_zoom <= 1.0 do
    if available?() do
      padding = max(1.0 - face_zoom, 0.0)

      case Image.FaceDetection.crop_largest(image, padding: padding) do
        {:ok, cropped} -> {:ok, cropped}
        {:error, :no_face_detected} -> {:error, :no_face}
        {:error, _other} -> {:error, :no_face}
      end
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Pixelates the regions of an image occupied by detected
  faces, leaving the rest of the image untouched.

  Used by Cloudinary's `e_pixelate_faces`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `scale` is the pixelation scale factor (smaller =
    chunkier blocks). Same convention as `Image.pixelate/2`.

  ### Returns

  * `{:ok, image_with_pixelated_faces}` on success — the
    returned image has the same dimensions as the input.

  * `{:ok, image}` (unchanged) when no faces are detected —
    nothing to pixelate.

  * `{:error, :unavailable}` if `Image.FaceDetection` isn't
    loaded.

  * `{:error, reason}` if `Image.crop/4`, `Image.pixelate/2`, or
    `Image.compose/3` fails when reconstructing the result.
  """
  @spec pixelate_faces(Vimage.t(), float()) ::
          {:ok, Vimage.t()} | {:error, :unavailable | term()}
  def pixelate_faces(%Vimage{} = image, scale)
      when is_number(scale) and scale > 0.0 do
    if available?() do
      faces = Image.FaceDetection.detect(image)
      do_pixelate_faces(image, faces, scale)
    else
      {:error, :unavailable}
    end
  end

  defp do_pixelate_faces(image, [], _scale), do: {:ok, image}

  defp do_pixelate_faces(image, faces, scale) do
    # Composite a pixelated copy of each face's region back
    # onto the original. Each face is processed independently
    # so partial overlaps don't compound the effect.
    Enum.reduce_while(faces, {:ok, image}, fn %{box: {x, y, w, h}}, {:ok, acc} ->
      case pixelate_region(acc, x, y, w, h, scale) do
        {:ok, _} = success -> {:cont, success}
        other -> {:halt, other}
      end
    end)
  end

  defp pixelate_region(image, x, y, w, h, scale) do
    with {:ok, region} <- Image.crop(image, x, y, w, h),
         {:ok, pixelated} <- Image.pixelate(region, scale) do
      Image.compose(image, pixelated, x: x, y: y)
    end
  end
end
