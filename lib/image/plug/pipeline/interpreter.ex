defmodule Image.Plug.Pipeline.Interpreter do
  @moduledoc """
  Executes a normalised pipeline against an open `Vix.Vips.Image`.

  The interpreter is a single `Enum.reduce_while/3` over the op list
  with one `apply_op/2` clause per op kind. There is no implicit
  reordering — `Image.Plug.Pipeline.Normaliser` runs first, so the
  ops arrive in canonical order with no-ops already folded away.
  """

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops

  @doc """
  Runs the pipeline.

  ### Arguments

  * `pipeline` is a normalised `Image.Plug.Pipeline` struct.

  * `image` is an open `Vix.Vips.Image`.

  * `options` is a keyword list of context the interpreter may
    need for ops that reference external resources.

  ### Options

  * `:resolve_layer_source` — a 1-arity function
    `fn %Image.Plug.Source{} -> {:ok, Vix.Vips.Image.t()} | {:error, term()} end`
    used by the `Image.Plug.Pipeline.Ops.Draw` clause to fetch
    overlay images. The plug passes a closure over its configured
    `Image.Plug.SourceResolver`. If omitted and a Draw op is
    encountered, the interpreter returns `:invalid_option`.

  ### Returns

  * `{:ok, image}` on success.

  * `{:error, %Image.Plug.Error{}}` on the first failed op.

  """
  @spec execute(Pipeline.t(), Vix.Vips.Image.t(), keyword()) ::
          {:ok, Vix.Vips.Image.t()} | {:error, Error.t()}
  def execute(pipeline, image, options \\ [])

  def execute(%Pipeline{ops: ops}, %Vix.Vips.Image{} = image, options) when is_list(options) do
    Enum.reduce_while(ops, {:ok, image}, fn op, {:ok, acc} ->
      case apply_op(op, acc, options) do
        {:ok, _} = success -> {:cont, success}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # ---------- Resize ----------

  defp apply_op(%Ops.Resize{} = resize, image, _options) do
    do_resize(resize, image)
  end

  # ---------- Rotate / Flip ----------

  defp apply_op(%Ops.Rotate{angle: 0}, image, _options), do: {:ok, image}

  defp apply_op(%Ops.Rotate{angle: angle}, image, _options) do
    case Image.rotate(image, angle * 1.0) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("rotate", reason)}
    end
  end

  defp apply_op(%Ops.Flip{direction: :horizontal}, image, _options) do
    case Image.flip(image, :horizontal) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("flip", reason)}
    end
  end

  defp apply_op(%Ops.Flip{direction: :vertical}, image, _options) do
    case Image.flip(image, :vertical) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("flip", reason)}
    end
  end

  defp apply_op(%Ops.Flip{direction: :both}, image, _options) do
    with {:ok, h} <- Image.flip(image, :horizontal),
         {:ok, _} = success <- Image.flip(h, :vertical) do
      success
    else
      {:error, reason} -> {:error, op_error("flip", reason)}
    end
  end

  # ---------- Trim ----------

  defp apply_op(%Ops.Trim{mode: :border, threshold: t}, image, _options) do
    case Image.trim(image, threshold: t) do
      {:ok, _} = success ->
        success

      {:error, reason} ->
        # `Image.trim/2` returns an `%Image.Error{}` whose message
        # contains "uncropped" when the image is uniform background.
        # Treat that as a no-op rather than a pipeline failure.
        if uncropped?(reason) do
          {:ok, image}
        else
          {:error, op_error("trim", reason)}
        end
    end
  end

  defp apply_op(
         %Ops.Trim{mode: :explicit, top: top, right: right, bottom: bottom, left: left},
         image,
         _options
       ) do
    width = Image.width(image)
    height = Image.height(image)
    crop_w = max(width - left - right, 1)
    crop_h = max(height - top - bottom, 1)

    case Image.crop(image, left, top, crop_w, crop_h) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("trim", reason)}
    end
  end

  # ---------- Crop ----------

  # Pixel coordinates pass straight through to `Image.crop/5`. The
  # source dimensions are read at apply time so an out-of-bounds
  # region can be clamped (the IIIF spec wants a 400 with a "could
  # be returned smaller than requested" note rather than a hard
  # rejection).
  defp apply_op(%Ops.Crop{units: :pixels, x: x, y: y, width: w, height: h}, image, _options) do
    do_crop(image, trunc(x), trunc(y), trunc(w), trunc(h))
  end

  # Percentage coordinates resolve against the actual source
  # dimensions at apply time. Same op can therefore be reused
  # across sources of different sizes — useful for IIIF's
  # `pct:x,y,w,h` region form.
  defp apply_op(%Ops.Crop{units: :percent, x: x, y: y, width: w, height: h}, image, _options) do
    src_w = Image.width(image)
    src_h = Image.height(image)
    px = trunc(src_w * x / 100)
    py = trunc(src_h * y / 100)
    pw = trunc(src_w * w / 100)
    ph = trunc(src_h * h / 100)
    do_crop(image, px, py, pw, ph)
  end

  # ---------- Adjust ----------

  defp apply_op(%Ops.Adjust{} = adjust, image, _options) do
    do_adjust(adjust, image)
  end

  # ---------- Sharpen / Blur ----------

  defp apply_op(%Ops.Sharpen{sigma: sigma}, image, _options) when sigma > 0 do
    case Image.sharpen(image, sigma: sigma) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("sharpen", reason)}
    end
  end

  defp apply_op(%Ops.Sharpen{}, image, _options), do: {:ok, image}

  defp apply_op(%Ops.Blur{sigma: sigma}, image, _options) when sigma > 0 do
    case Image.blur(image, sigma: sigma) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("blur", reason)}
    end
  end

  defp apply_op(%Ops.Blur{}, image, _options), do: {:ok, image}

  # ---------- Background ----------

  defp apply_op(%Ops.Background{color: color}, image, _options) do
    case Image.flatten(image, background: color) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("background", reason)}
    end
  end

  # ---------- Colorspace ----------

  defp apply_op(%Ops.Colorspace{target: target}, image, _options) do
    case Image.to_colorspace(image, target) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("colorspace", reason)}
    end
  end

  # ---------- IccTransform ----------

  defp apply_op(%Ops.IccTransform{profile: profile, intent: intent}, image, _options) do
    case Image.to_colorspace(image, profile, intent: intent) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("icc_transform", reason)}
    end
  end

  # ---------- ReplaceColor ----------

  defp apply_op(%Ops.ReplaceColor{} = replace, image, _options) do
    case Image.replace_color(image, replace_color_options(replace)) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("replace_color", reason)}
    end
  end

  # ---------- Border ----------

  defp apply_op(%Ops.Border{} = border, image, _options) do
    do_border(border, image)
  end

  # ---------- Enhance ----------

  defp apply_op(%Ops.Enhance{}, image, _options) do
    case Image.enhance(image) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("enhance", reason)}
    end
  end

  # ---------- Vignette ----------

  defp apply_op(%Ops.Vignette{strength: +0.0}, image, _options), do: {:ok, image}

  defp apply_op(%Ops.Vignette{strength: strength}, image, _options) do
    case Image.vignette(image, strength: strength) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("vignette", reason)}
    end
  end

  # ---------- Sepia ----------

  defp apply_op(%Ops.Sepia{strength: +0.0}, image, _options), do: {:ok, image}

  defp apply_op(%Ops.Sepia{strength: strength}, image, _options) do
    case Image.sepia(image, strength) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("sepia", reason)}
    end
  end

  # ---------- Tint ----------

  defp apply_op(%Ops.Tint{color: color}, image, _options) do
    case Image.tint(image, color) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("tint", reason)}
    end
  end

  # ---------- Opacity ----------

  defp apply_op(%Ops.Opacity{factor: 1.0}, image, _options), do: {:ok, image}

  defp apply_op(%Ops.Opacity{factor: factor}, image, _options) do
    case Image.opacity(image, factor) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("opacity", reason)}
    end
  end

  # ---------- Pixelate ----------

  defp apply_op(%Ops.Pixelate{scale: scale}, image, _options) when scale >= 1.0,
    do: {:ok, image}

  defp apply_op(%Ops.Pixelate{scale: scale}, image, _options) do
    case Image.pixelate(image, scale) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("pixelate", reason)}
    end
  end

  # ---------- PixelateFaces ----------
  #
  # Falls back to no-op when `:image_vision` isn't loaded —
  # users get a normal image (rather than an error) so the
  # request still succeeds. Document as ⚠️ in the conformance
  # guides.
  defp apply_op(%Ops.PixelateFaces{scale: scale}, image, _options) when scale >= 1.0,
    do: {:ok, image}

  defp apply_op(%Ops.PixelateFaces{scale: scale}, image, _options) do
    case Image.Plug.FaceAware.pixelate_faces(image, scale) do
      {:ok, _} = success -> success
      {:error, :unavailable} -> {:ok, image}
      {:error, reason} -> {:error, op_error("pixelate_faces", reason)}
    end
  end

  # ---------- Posterize ----------

  defp apply_op(%Ops.Posterize{levels: 256}, image, _options), do: {:ok, image}

  defp apply_op(%Ops.Posterize{levels: levels}, image, _options) do
    case Image.posterize(image, levels) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("posterize", reason)}
    end
  end

  # ---------- Rounded ----------

  defp apply_op(%Ops.Rounded{radius: :max}, image, _options) do
    radius = div(min(Image.width(image), Image.height(image)), 2)

    case Image.rounded(image, radius: radius) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("rounded", reason)}
    end
  end

  defp apply_op(%Ops.Rounded{radius: radius}, image, _options) when is_integer(radius) do
    case Image.rounded(image, radius: radius) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("rounded", reason)}
    end
  end

  # ---------- DropShadow ----------

  defp apply_op(%Ops.DropShadow{} = shadow, image, _options) do
    case Image.drop_shadow(image,
           color: shadow.color,
           opacity: shadow.opacity,
           sigma: shadow.sigma,
           dx: shadow.dx,
           dy: shadow.dy
         ) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("drop_shadow", reason)}
    end
  end

  # ---------- Fade ----------

  defp apply_op(%Ops.Fade{edges: edges, length: length}, image, _options) do
    case Image.fade(image, edges: edges, length: length) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("fade", reason)}
    end
  end

  # ---------- Orientation ----------

  defp apply_op(%Ops.Orientation{value: value}, image, _options) do
    case Image.set_orientation(image, value) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("orientation", reason)}
    end
  end

  # ---------- Segment (placeholder) ----------

  defp apply_op(%Ops.Segment{}, image, _options) do
    # Subject segmentation lands in a later milestone. Carry the
    # image through unchanged.
    {:ok, image}
  end

  # ---------- Draw (overlays / watermarks) ----------

  defp apply_op(%Ops.Draw{layers: []}, _image, _options) do
    {:error, Error.new(:not_implemented, "draw op has no layers")}
  end

  defp apply_op(%Ops.Draw{layers: layers}, image, options) do
    case Keyword.fetch(options, :resolve_layer_source) do
      {:ok, resolver} when is_function(resolver, 1) ->
        compose_layers(image, layers, resolver)

      _ ->
        {:error,
         Error.new(
           :invalid_option,
           "interpreter cannot run a Draw op without a :resolve_layer_source function"
         )}
    end
  end

  defp apply_op(op, _image, _options) do
    {:error,
     Error.new(:not_implemented, "interpreter does not yet handle this op kind",
       details: %{op: inspect(op.__struct__)}
     )}
  end

  defp op_error(name, reason) do
    Error.new(:pipeline_failed, "#{name} failed", details: %{reason: format_reason(reason)})
  end

  defp uncropped?(%{message: message}) when is_binary(message), do: message =~ "uncropped"

  # ---------- Crop helpers ----------

  # Clamp to the source bounds so out-of-range regions (which
  # IIIF's spec permits the server to silently truncate) don't
  # crash libvips.
  defp do_crop(image, x, y, w, h) do
    src_w = Image.width(image)
    src_h = Image.height(image)
    clamp_x = x |> max(0) |> min(src_w - 1)
    clamp_y = y |> max(0) |> min(src_h - 1)
    clamp_w = w |> max(1) |> min(src_w - clamp_x)
    clamp_h = h |> max(1) |> min(src_h - clamp_y)

    case Image.crop(image, clamp_x, clamp_y, clamp_w, clamp_h) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("crop", reason)}
    end
  end

  # ---------- Adjust helpers ----------

  defp do_adjust(adjust, image) do
    image
    |> apply_brightness(adjust.brightness)
    |> apply_then(&apply_contrast(&1, adjust.contrast))
    |> apply_then(&apply_saturation(&1, adjust.saturation))
    |> apply_then(&apply_gamma(&1, adjust.gamma))
  end

  defp apply_then({:ok, image}, fun), do: fun.(image)
  defp apply_then({:error, _} = error, _fun), do: error

  defp apply_brightness(image, multiplier) when multiplier == 1.0, do: {:ok, image}

  defp apply_brightness(image, multiplier) do
    case Image.brightness(image, multiplier) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("brightness", reason)}
    end
  end

  defp apply_contrast(image, multiplier) when multiplier == 1.0, do: {:ok, image}

  defp apply_contrast(image, multiplier) do
    case Image.contrast(image, multiplier) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("contrast", reason)}
    end
  end

  defp apply_saturation(image, multiplier) when multiplier == 1.0, do: {:ok, image}

  defp apply_saturation(image, multiplier) do
    case Image.saturation(image, multiplier) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("saturation", reason)}
    end
  end

  defp apply_gamma(image, multiplier) when multiplier == 1.0, do: {:ok, image}

  defp apply_gamma(image, multiplier) do
    case Image.gamma(image, multiplier) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("gamma", reason)}
    end
  end

  # ---------- Draw helpers ----------

  defp compose_layers(base_image, layers, resolver) do
    Enum.reduce_while(layers, {:ok, base_image}, fn layer, {:ok, base} ->
      case render_layer(base, layer, resolver) do
        {:ok, _} = success -> {:cont, success}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp render_layer(base, %Ops.Draw.Layer{} = layer, resolver) do
    with {:ok, overlay} <- resolver.(layer.source),
         {:ok, sized} <- maybe_resize_layer(overlay, layer),
         {:ok, rotated} <- maybe_rotate_layer(sized, layer.rotate),
         {x, y} = layer_position(base, rotated, layer.position),
         {:ok, _} = success <- Image.compose(base, rotated, x: x, y: y) do
      success
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, op_error("draw", reason)}
    end
  end

  defp maybe_resize_layer(overlay, %Ops.Draw.Layer{width: nil, height: nil}), do: {:ok, overlay}

  defp maybe_resize_layer(overlay, %Ops.Draw.Layer{width: w, height: h, fit: fit}) do
    target_w = w || Image.width(overlay)
    target_h = h || Image.height(overlay)

    case Image.thumbnail(overlay, "#{target_w}x#{target_h}", fit: thumbnail_fit_for_layer(fit)) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("draw layer resize", reason)}
    end
  end

  defp thumbnail_fit_for_layer(:cover), do: :cover
  defp thumbnail_fit_for_layer(:crop), do: :cover
  defp thumbnail_fit_for_layer(_other), do: :contain

  defp maybe_rotate_layer(image, 0), do: {:ok, image}

  defp maybe_rotate_layer(image, angle) when angle in [90, 180, 270] do
    case Image.rotate(image, angle * 1.0) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("draw layer rotate", reason)}
    end
  end

  defp maybe_rotate_layer(image, _other), do: {:ok, image}

  defp layer_position(base, overlay, nil) do
    {center_x(Image.width(base), Image.width(overlay)),
     center_y(Image.height(base), Image.height(overlay))}
  end

  defp layer_position(base, overlay, {:offset, sides}) do
    base_w = Image.width(base)
    base_h = Image.height(base)
    overlay_w = Image.width(overlay)
    overlay_h = Image.height(overlay)

    x =
      cond do
        is_integer(sides[:left]) -> sides[:left]
        is_integer(sides[:right]) -> max(base_w - overlay_w - sides[:right], 0)
        true -> center_x(base_w, overlay_w)
      end

    y =
      cond do
        is_integer(sides[:top]) -> sides[:top]
        is_integer(sides[:bottom]) -> max(base_h - overlay_h - sides[:bottom], 0)
        true -> center_y(base_h, overlay_h)
      end

    {x, y}
  end

  # ---------- ReplaceColor helpers ----------

  defp replace_color_options(%Ops.ReplaceColor{
         to: to,
         from: from,
         threshold: threshold,
         less_than: less_than,
         greater_than: greater_than,
         blend?: blend?
       }) do
    base = [replace_with: to, blend: blend?]

    if not is_nil(less_than) and not is_nil(greater_than) do
      [{:less_than, less_than}, {:greater_than, greater_than} | base]
    else
      [{:color, from}, {:threshold, threshold} | base]
    end
  end

  # ---------- Border helpers ----------

  defp do_border(%Ops.Border{} = border, image) do
    width = Image.width(image) + border.left + border.right
    height = Image.height(image) + border.top + border.bottom

    case Image.embed(image, width, height,
           x: border.left,
           y: border.top,
           background: border.color
         ) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("border", reason)}
    end
  end

  # `size_pct` — resize by a percentage of the source dimensions.
  # Maps to IIIF's `pct:N` size form. Computes the target pixel
  # dimensions from the source size at apply time, then delegates
  # to the standard width/height path so all the same fit /
  # gravity / face-aware logic applies.
  defp do_resize(%Ops.Resize{size_pct: pct} = resize, image)
       when is_number(pct) and pct > 0 do
    src_w = Image.width(image)
    src_h = Image.height(image)
    new_w = max(trunc(src_w * pct / 100), 1)
    new_h = max(trunc(src_h * pct / 100), 1)
    do_resize(%{resize | size_pct: nil, width: new_w, height: new_h}, image)
  end

  defp do_resize(%Ops.Resize{width: width, height: height} = resize, image)
       when not is_nil(width) or not is_nil(height) do
    {target_width, target_height} = resolve_dimensions(resize, image)
    dimensions = "#{target_width}x#{target_height}"

    # Face-aware pre-crop. When the caller asked for
    # `gravity: :face` and `:image_vision` is loaded, narrow
    # the source to the largest detected face (with padding
    # derived from `face_zoom`) before the regular thumbnail
    # resize pass. The thumbnail then sees a face-centred
    # region and produces a face-centred thumbnail. Falls
    # through to the normal flow when face detection isn't
    # available or no face is detected — the existing
    # `:attention` saliency crop takes over.
    {prepared_image, prepared_resize} = maybe_face_aware_precrop(image, resize)

    options = thumbnail_options(prepared_resize)

    case Image.thumbnail(prepared_image, dimensions, options) do
      {:ok, thumbnailed} ->
        thumbnailed
        |> maybe_compass_crop(prepared_resize, target_width, target_height)
        |> apply_then(&maybe_pad(prepared_resize, &1, target_width, target_height))

      {:error, reason} ->
        {:error,
         Error.new(:pipeline_failed, "Image.thumbnail failed",
           details: %{reason: format_reason(reason)}
         )}
    end
  end

  defp do_resize(_resize, image) do
    {:ok, image}
  end

  # Pre-crop helper. Returns the (possibly narrowed) image
  # plus the (possibly modified) Resize op.  When the face
  # crop succeeds we drop the gravity to `:center` so the
  # downstream thumbnail does a centred resize on the cropped
  # region rather than re-running attention saliency.
  defp maybe_face_aware_precrop(image, %Ops.Resize{gravity: :face, face_zoom: face_zoom} = resize) do
    case Image.Plug.FaceAware.face_crop(image, face_zoom) do
      {:ok, cropped} ->
        {cropped, %{resize | gravity: :center}}

      {:error, _reason} ->
        {image, resize}
    end
  end

  defp maybe_face_aware_precrop(image, resize), do: {image, resize}

  defp resolve_dimensions(%Ops.Resize{width: width, height: height, dpr: dpr}, image) do
    {source_width, source_height} = {Image.width(image), Image.height(image)}

    target_width =
      case width do
        :auto -> source_width
        nil -> infer_from(height, source_height, source_width)
        n when is_integer(n) -> n
      end

    target_height =
      case height do
        nil -> infer_from(width_for_aspect(width, source_width), source_width, source_height)
        n when is_integer(n) -> n
      end

    {target_width * dpr, target_height * dpr}
  end

  defp width_for_aspect(:auto, source_width), do: source_width
  defp width_for_aspect(nil, source_width), do: source_width
  defp width_for_aspect(n, _source_width) when is_integer(n), do: n

  defp infer_from(other_dim, source_other_dim, source_dim) do
    max(round(source_dim * other_dim / source_other_dim), 1)
  end

  defp thumbnail_options(%Ops.Resize{fit: :contain}) do
    [fit: :contain]
  end

  defp thumbnail_options(%Ops.Resize{fit: :cover, gravity: gravity}) do
    [fit: :cover, crop: gravity_to_crop(gravity)]
  end

  defp thumbnail_options(%Ops.Resize{fit: :crop, gravity: gravity}) do
    [fit: :cover, crop: gravity_to_crop(gravity), resize: :down]
  end

  defp thumbnail_options(%Ops.Resize{fit: :scale_down}) do
    [fit: :contain, resize: :down]
  end

  defp thumbnail_options(%Ops.Resize{fit: :pad}) do
    [fit: :contain]
  end

  defp thumbnail_options(%Ops.Resize{fit: :squeeze}) do
    [fit: :fill]
  end

  # libvips' `thumbnail` only takes `:none | :center | :entropy |
  # :attention | :low | :high` for `:crop`. Compass directions and
  # explicit `{:xy, _, _}` focal points are handled in two steps:
  # thumbnail with `crop: :none` and then `Image.crop/5` to the
  # requested position. `gravity_to_crop/1` returns `:center` for
  # those gravities; `maybe_compass_crop/4` finishes the job.
  defp gravity_to_crop(:center), do: :center
  defp gravity_to_crop(:auto), do: :attention
  defp gravity_to_crop(:face), do: :attention
  defp gravity_to_crop(_other), do: :center

  # When the gravity is a compass direction or a normalised x/y, the
  # thumbnail above produces an oversized image (because we passed
  # `crop: :center` to libvips) and we then crop to position. For
  # `:center` and `:auto`/`:face`/`:entropy` libvips already cropped
  # correctly so this is a no-op.
  defp maybe_compass_crop(image, %Ops.Resize{fit: fit, gravity: gravity}, target_w, target_h)
       when fit in [:cover, :crop] and
              gravity not in [:center, :auto, :face, :entropy, :attention] do
    width = Image.width(image)
    height = Image.height(image)
    {x, y} = focal_offset(gravity, width, height, target_w, target_h)

    case Image.crop(image, x, y, min(target_w, width), min(target_h, height)) do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, op_error("crop", reason)}
    end
  end

  defp maybe_compass_crop(image, _resize, _target_w, _target_h), do: {:ok, image}

  defp focal_offset(:north, w, _h, tw, _th), do: {center_x(w, tw), 0}
  defp focal_offset(:south, w, h, tw, th), do: {center_x(w, tw), max(h - th, 0)}
  defp focal_offset(:east, w, h, tw, th), do: {max(w - tw, 0), center_y(h, th)}
  defp focal_offset(:west, _w, h, _tw, th), do: {0, center_y(h, th)}
  defp focal_offset(:north_east, w, _h, tw, _th), do: {max(w - tw, 0), 0}
  defp focal_offset(:north_west, _w, _h, _tw, _th), do: {0, 0}
  defp focal_offset(:south_east, w, h, tw, th), do: {max(w - tw, 0), max(h - th, 0)}
  defp focal_offset(:south_west, _w, h, _tw, th), do: {0, max(h - th, 0)}

  defp focal_offset({:xy, fx, fy}, w, h, tw, th) do
    x = round((w - tw) * fx) |> clamp_offset(w - tw)
    y = round((h - th) * fy) |> clamp_offset(h - th)
    {x, y}
  end

  defp focal_offset(_other, w, h, tw, th), do: {center_x(w, tw), center_y(h, th)}

  defp center_x(w, tw), do: max(div(w - tw, 2), 0)
  defp center_y(h, th), do: max(div(h - th, 2), 0)
  defp clamp_offset(value, _max) when value < 0, do: 0
  defp clamp_offset(value, max) when value > max, do: max(max, 0)
  defp clamp_offset(value, _max), do: value

  defp maybe_pad(%Ops.Resize{fit: :pad}, image, width, height) do
    case Image.embed(image, width, height, background: :white) do
      {:ok, _} = success ->
        success

      {:error, reason} ->
        {:error,
         Error.new(:pipeline_failed, "Image.embed (pad) failed",
           details: %{reason: format_reason(reason)}
         )}
    end
  end

  defp maybe_pad(_resize, image, _width, _height), do: {:ok, image}

  # Image.write/3 / Image.thumbnail/3 / Image.embed/4 always return
  # `{:error, %Image.Error{message: binary}}` on failure. The
  # `:uncropped` atom from Image.trim/2 is handled by the caller
  # before reaching here.
  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
end
