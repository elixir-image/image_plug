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

    case buffer do
      :stream ->
        stream = Image.stream!(image, [{:suffix, suffix} | write_options])
        {:ok, {:stream, stream}, content_type}

      :bytes ->
        case Image.write(image, :memory, [{:suffix, suffix} | write_options]) do
          {:ok, bytes} -> {:ok, {:bytes, bytes}, content_type}
          {:error, reason} -> {:error, encode_error(reason)}
        end
    end
  rescue
    e in Image.Error ->
      {:error, encode_error(e)}
  end

  defp format_settings(%Ops.Format{type: :jpeg, quality: q, metadata: m}) do
    {".jpg", "image/jpeg", [quality: q] ++ strip_metadata_option(m)}
  end

  defp format_settings(%Ops.Format{type: :baseline_jpeg, quality: q, metadata: m}) do
    {".jpg", "image/jpeg", [quality: q, progressive: false] ++ strip_metadata_option(m)}
  end

  defp format_settings(%Ops.Format{type: :png, metadata: m}) do
    {".png", "image/png", strip_metadata_option(m)}
  end

  defp format_settings(%Ops.Format{type: :webp, quality: q, metadata: m}) do
    {".webp", "image/webp", [quality: q] ++ strip_metadata_option(m)}
  end

  defp format_settings(%Ops.Format{type: :avif, quality: q, metadata: m}) do
    {".avif", "image/avif", [quality: q] ++ strip_metadata_option(m)}
  end

  defp strip_metadata_option(:keep), do: []
  defp strip_metadata_option(:none), do: [strip_metadata: true]
  # In M3 we still strip everything for `:copyright` — selective
  # copyright preservation needs a small read-then-write helper that
  # arrives in M6 alongside the rest of the cache-headers/policy work.
  defp strip_metadata_option(:copyright), do: [strip_metadata: true]

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
