defmodule Image.Plug.Pipeline.Encoder do
  @moduledoc """
  Serialises a transformed `Vix.Vips.Image` into bytes for the HTTP
  response.

  Returns `{:ok, body, content_type}` where `body` is one of:

  * `{:stream, Enumerable.t()}` — preferred. Backed by
    `Image.stream!/2`, which wraps `Vix.Vips.Image.write_to_stream/2`
    so libvips emits encoded bytes chunk-by-chunk.

  * `{:bytes, iodata()}` — fallback for callers that need the
    response fully buffered (HEAD requests, hosts that disable
    chunked transfer, the `format=json` output).

  ### Canonical streaming pipeline

  The full source-to-client chain mirrors the canonical shape
  documented in the
  [`Image` library's stream test suite](https://github.com/kipcole9/image/blob/main/test/stream_image_test.exs):

      path
      |> File.stream!(2048, [])      # Image.Plug.SourceResolver.File
      |> Image.open()                # ditto
      |> ...transforms...            # Image.Plug.Pipeline.Interpreter
      |> Image.stream!(suffix: ext)  # this module's `:stream` body
      |> Enum.reduce_while(conn, fn chunk, conn ->
           case Plug.Conn.chunk(conn, chunk) do
             {:ok, conn}      -> {:cont, conn}
             {:error, :closed} -> {:halt, conn}
           end
         end)                        # Image.Plug.Plug.send_body/4

  `Image.write(image, conn, suffix: ext)` does the chunked-write
  loop internally and is functionally identical to that
  `reduce_while` block. We keep the loop in our own plug so we
  retain explicit control over the conn for header manipulation,
  error fallbacks, and telemetry.

  ### Format support

  M3 supports JPEG, baseline JPEG, PNG, WebP, AVIF, the
  Accept-driven `:auto` selection, and the small `:json` metadata
  endpoint.

  ### AVIF fallback

  If libvips lacks AVIF write support, requests for `format=avif`
  encode to WebP and the response is tagged with the
  `x-image-plug-format-fallback: avif->webp` header. The plug
  forwards the header set by the encoder. Detection runs once at
  application boot via `Image.Plug.Capabilities.probe/0`.
  """

  alias Image.Plug.{Capabilities, Error}
  alias Image.Plug.Pipeline.Ops

  @typedoc """
  The encoded body. Streaming form is preferred; the bytes form is
  used when buffering is requested or required.
  """
  @type body :: {:stream, Enumerable.t()} | {:bytes, iodata()}

  @typedoc """
  Optional response headers the plug should add. Keys are lowercase
  binaries.
  """
  @type extra_headers :: [{String.t(), String.t()}]

  @doc """
  Encodes the working image according to the pipeline's `Ops.Format`.

  ### Arguments

  * `image` is the transformed `Vix.Vips.Image`.

  * `format` is the pipeline's `Image.Plug.Pipeline.Ops.Format`
    struct. The encoder reads `:type`, `:quality`, and `:metadata`.

  * `encode_options` is a keyword list:

  ### Options

  * `:buffer` — `:stream` (default) or `:bytes`. Controls whether the
    body is returned as a stream or as buffered iodata. The `:json`
    output is always buffered regardless of this setting.

  * `:source_content_type` — the source image's MIME type. Used by
    the `:auto` selector as the final fallback when neither AVIF nor
    WebP is acceptable.

  * `:accept` — the request's `Accept` header value (a single string
    or `nil`). Used by the `:auto` selector to negotiate the output
    format.

  ### Returns

  * `{:ok, body, content_type}` on success.

  * `{:ok, body, content_type, extra_headers}` when the encoder
    needs to add response headers (currently only the AVIF fallback).

  * `{:error, %Image.Plug.Error{}}` on encode failure.

  """
  @spec encode(Vix.Vips.Image.t(), Ops.Format.t(), keyword()) ::
          {:ok, body(), String.t()}
          | {:ok, body(), String.t(), extra_headers()}
          | {:error, Error.t()}
  def encode(image, format, encode_options \\ [])

  # ---------- :auto ----------

  def encode(%Vix.Vips.Image{} = image, %Ops.Format{type: :auto} = format, encode_options) do
    chosen = pick_auto_format(encode_options)
    encode(image, %{format | type: chosen}, encode_options)
  end

  # ---------- :avif (with soft fallback) ----------

  def encode(%Vix.Vips.Image{} = image, %Ops.Format{type: :avif} = format, encode_options) do
    if Capabilities.avif_write?() do
      do_encode_raster(image, format, encode_options)
    else
      fallback = %{format | type: :webp}

      case do_encode_raster(image, fallback, encode_options) do
        {:ok, body, content_type} ->
          {:ok, body, content_type, [{"x-image-plug-format-fallback", "avif->webp"}]}

        {:error, _} = error ->
          error
      end
    end
  end

  # ---------- raster formats ----------

  def encode(%Vix.Vips.Image{} = image, %Ops.Format{type: type} = format, encode_options)
      when type in [:jpeg, :baseline_jpeg, :png, :webp] do
    do_encode_raster(image, format, encode_options)
  end

  # ---------- json ----------

  def encode(%Vix.Vips.Image{} = image, %Ops.Format{type: :json}, _encode_options) do
    body = %{
      "width" => Image.width(image),
      "height" => Image.height(image),
      "bands" => Image.bands(image),
      "has_alpha" => Image.has_alpha?(image)
    }

    iodata = :json.encode(body)
    {:ok, {:bytes, iodata}, "application/json"}
  end

  def encode(_image, %Ops.Format{type: type}, _encode_options) do
    {:error,
     Error.new(:unsupported_output_format, "encoder does not support this format",
       details: %{requested: type}
     )}
  end

  # ---------- raster encode helper ----------

  defp do_encode_raster(image, %Ops.Format{} = format, encode_options) do
    buffer = Keyword.get(encode_options, :buffer, :stream)
    {suffix, content_type, write_options} = format_settings(format)

    case prepare_metadata(image, format.metadata) do
      {:ok, prepared} ->
        encode_buffered_or_streamed(prepared, suffix, content_type, write_options, buffer)

      {:error, reason} ->
        {:error, encode_error(reason)}
    end
  rescue
    e in Image.Error ->
      {:error, encode_error(e)}
  end

  defp encode_buffered_or_streamed(image, suffix, content_type, write_options, :stream) do
    stream = Image.stream!(image, [{:suffix, suffix} | write_options])
    {:ok, {:stream, stream}, content_type}
  end

  defp encode_buffered_or_streamed(image, suffix, content_type, write_options, :bytes) do
    case Image.write(image, :memory, [{:suffix, suffix} | write_options]) do
      {:ok, bytes} -> {:ok, {:bytes, bytes}, content_type}
      {:error, reason} -> {:error, encode_error(reason)}
    end
  end

  defp format_settings(%Ops.Format{type: :jpeg} = f) do
    {".jpg", "image/jpeg",
     [quality: f.quality]
     |> append_progressive(f.progressive)
     |> append_chroma_subsampling(f.chroma_subsampling)
     |> append_strip_metadata(f.metadata)}
  end

  defp format_settings(%Ops.Format{type: :baseline_jpeg} = f) do
    {".jpg", "image/jpeg",
     [quality: f.quality, progressive: false]
     |> append_chroma_subsampling(f.chroma_subsampling)
     |> append_strip_metadata(f.metadata)}
  end

  defp format_settings(%Ops.Format{type: :png} = f) do
    {".png", "image/png",
     []
     |> append_progressive(f.progressive)
     |> append_lossy(f.lossy)
     |> append_strip_metadata(f.metadata)}
  end

  defp format_settings(%Ops.Format{type: :webp} = f) do
    {".webp", "image/webp",
     [quality: f.quality]
     |> append_lossy(f.lossy)
     |> append_strip_metadata(f.metadata)}
  end

  defp format_settings(%Ops.Format{type: :avif} = f) do
    {".avif", "image/avif",
     [quality: f.quality]
     |> append_lossy(f.lossy)
     |> append_chroma_subsampling(f.chroma_subsampling)
     |> append_strip_metadata(f.metadata)}
  end

  defp append_progressive(opts, nil), do: opts
  defp append_progressive(opts, value) when is_boolean(value), do: opts ++ [progressive: value]

  defp append_lossy(opts, nil), do: opts
  defp append_lossy(opts, value) when is_boolean(value), do: opts ++ [lossy: value]

  defp append_chroma_subsampling(opts, nil), do: opts

  defp append_chroma_subsampling(opts, mode) when mode in [:auto, :on, :off],
    do: opts ++ [chroma_subsampling: mode]

  # `:copyright` metadata is materialised by `prepare_metadata/2`
  # before encoding (`Image.minimize_metadata/2` rewrites only the
  # copyright field onto the image), so the encoder asks libvips
  # to preserve everything that survives.
  defp append_strip_metadata(opts, :keep), do: opts
  defp append_strip_metadata(opts, :none), do: opts ++ [strip_metadata: true]
  defp append_strip_metadata(opts, :copyright), do: opts

  # `:copyright` runs `Image.minimize_metadata/2` with a `:keep`
  # list so the encoded output retains only the copyright field.
  # `:keep` and `:none` need no pre-encode mutation — libvips
  # handles them via the `strip_metadata` write option.
  defp prepare_metadata(image, :keep), do: {:ok, image}
  defp prepare_metadata(image, :none), do: {:ok, image}

  # Always preserve orientation alongside copyright — otherwise
  # an image stored with `EXIF Orientation = 6` would deliver
  # rotated incorrectly through the plug. Callers who want every
  # tag stripped (including orientation) should pass
  # `metadata=:none`.
  #
  # `Image.minimize_metadata/2` calls `Image.exif/1` internally,
  # which raises a `WithClauseError` on certain images whose
  # EXIF blob is TIFF-formatted but missing the `"Exif\\0\\0"`
  # prefix. Treat any unexpected failure as "fall back to leaving
  # metadata alone" so a malformed EXIF blob never breaks the
  # encode path.
  defp prepare_metadata(image, :copyright) do
    # `Image.minimize_metadata/2`'s `:keep` list reads from the
    # source EXIF blob, but `Image.set_orientation/2` mutates a
    # live header field that isn't part of that blob. Snapshot
    # the live `orientation` header before minimisation and
    # restore it after so an explicit `or=N`-driven override
    # survives the metadata strip.
    #
    # `Image.minimize_metadata/2` calls `Image.exif/1`, which
    # returns `{:error, %Image.Error{reason: :invalid_exif}}`
    # on images whose EXIF blob is TIFF-formatted but missing
    # the `"Exif\\0\\0"` prefix (some PNGs from libpng's older
    # `iTXt` paths land here). Treat any failure as "leave
    # metadata alone" so a malformed source doesn't 500 the
    # request.
    orientation = read_live_orientation(image)

    case Image.minimize_metadata(image, keep: [:copyright, :orientation]) do
      {:ok, prepared} -> restore_orientation(prepared, orientation)
      {:error, _} -> {:ok, image}
    end
  rescue
    _ -> {:ok, image}
  end

  defp read_live_orientation(image) do
    case Vix.Vips.Image.header_value(image, "orientation") do
      {:ok, n} when is_integer(n) -> n
      _ -> nil
    end
  end

  defp restore_orientation(image, nil), do: {:ok, image}

  defp restore_orientation(image, orientation) when is_integer(orientation) do
    Image.set_orientation(image, orientation)
  end

  defp pick_auto_format(encode_options) do
    accept = Keyword.get(encode_options, :accept) || ""
    source_content_type = Keyword.get(encode_options, :source_content_type, "image/jpeg")

    cond do
      Capabilities.avif_write?() and accepts?(accept, "image/avif") -> :avif
      accepts?(accept, "image/webp") -> :webp
      true -> source_content_type_to_format(source_content_type)
    end
  end

  defp accepts?(accept, mime) when is_binary(accept) and is_binary(mime) do
    # Cheap substring match. The Accept grammar allows `*/*` and
    # `image/*` and weighted entries, but Cloudflare's behaviour is
    # likewise simple "if the literal type appears, use it"; we
    # match that.
    String.contains?(accept, mime) or
      String.contains?(accept, "image/*") or
      String.contains?(accept, "*/*")
  end

  defp source_content_type_to_format("image/png"), do: :png
  defp source_content_type_to_format("image/webp"), do: :webp
  defp source_content_type_to_format("image/avif"), do: :avif
  defp source_content_type_to_format("image/gif"), do: :png
  defp source_content_type_to_format("image/svg+xml"), do: :png
  # JPEG is the safest "everything renders this" fallback per Cloudflare.
  defp source_content_type_to_format(_other), do: :jpeg

  defp encode_error(%{message: message}) when is_binary(message) do
    Error.new(:pipeline_failed, "encode failed", details: %{reason: message})
  end

  defp encode_error(reason) do
    Error.new(:pipeline_failed, "encode failed", details: %{reason: inspect(reason)})
  end
end
