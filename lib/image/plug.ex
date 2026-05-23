defmodule Image.Plug do
  @moduledoc """
  The library's request entry point.

  Mount this plug under whatever path your host application uses (e.g.
  `forward "/img", to: Image.Plug, init_opts: [...]` for
  `Plug.Router`, or `plug Image.Plug, [...]` from a Phoenix
  endpoint).

  ### Request lifecycle

  Each request flows through:

  1. `provider.parse/2` — produces either a fully-formed pipeline +
     source, a variant lookup + source, or a passthrough source.

  2. Variant resolution against the configured
     `Image.Plug.VariantStore`. Variant URLs of the form
     `/<account>/<image-id>/<variant-name>` are expanded to the
     stored pipeline; ad-hoc URLs skip this step.

  3. `Image.Plug.Pipeline.Normaliser.normalise/1`.

  4. `source_resolver.load/2` — opens the source as a
     `Vix.Vips.Image`, preferring streaming decode.

  5. `Image.Plug.Pipeline.Interpreter.execute/2`.

  6. `Image.Plug.Pipeline.Encoder.encode/3` — produces a streaming
     body when possible.

  7. The plug pipes the body to the client via
     `Plug.Conn.send_chunked/2` + `Plug.Conn.chunk/2`. Buffered bytes
     bodies use `Plug.Conn.send_resp/3`.
  """

  @behaviour Plug

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Options

  require Logger

  @impl Plug
  @doc """
  Validates configuration and returns an opaque options struct passed
  through to every `call/2` invocation.

  Raises `ArgumentError` if required configuration is missing or
  malformed. Configuration errors are programmer errors and must surface
  at boot time, not per-request.
  """
  @spec init(keyword()) :: Options.t()
  def init(options) when is_list(options) do
    Options.new!(options)
  end

  @impl Plug
  @doc """
  Handles a single request end-to-end.
  """
  @spec call(Plug.Conn.t(), Options.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Options{} = options) do
    start_time = System.monotonic_time()
    metadata = %{request_path: conn.request_path, provider: options.provider}

    :telemetry.execute(
      options.telemetry_prefix ++ [:request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result =
        case run(conn, options) do
          {:ok, conn} ->
            conn

          {:error, %Error{} = error, context} ->
            respond_error(conn, error, options, context)
        end

      stop_metadata =
        Map.merge(metadata, %{status: result.status, error_tag: error_tag(result)})

      :telemetry.execute(
        options.telemetry_prefix ++ [:request, :stop],
        %{duration: System.monotonic_time() - start_time},
        stop_metadata
      )

      result
    catch
      kind, reason ->
        :telemetry.execute(
          options.telemetry_prefix ++ [:request, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp error_tag(%Plug.Conn{} = conn) do
    case Plug.Conn.get_resp_header(conn, "x-image-plug-error") do
      [tag | _] -> tag
      [] -> nil
    end
  end

  defp run(conn, options) do
    with :ok <- verify_signature(conn, options) |> wrap_unit(),
         {:ok, parsed} <- wrap(options.provider.parse(conn, options.provider_options)) do
      case parsed do
        {:info, kind, source} ->
          run_info(conn, kind, source, options)

        _ ->
          run_render(conn, parsed, options)
      end
    end
  end

  defp run_render(conn, parsed, options) do
    with {:ok, pipeline, source} <- wrap(resolve(parsed, options)),
         {:ok, normalised} <- wrap(Pipeline.Normaliser.normalise(pipeline)),
         {:ok, image, meta} <-
           wrap(options.source_resolver.load(source, options.source_resolver_options)) do
      chosen_format = chosen_format(normalised, accept_header(conn), meta)
      cache = Image.Plug.Cache.compute(meta, normalised, chosen_format)

      if Image.Plug.Cache.fresh?(conn, cache.etag) do
        {:ok, send_not_modified(conn, cache)}
      else
        case run_encode(conn, normalised, image, meta, options, cache) do
          {:ok, _} = ok -> ok
          {:error, %Error{} = error} -> {:error, error, %{image: image, meta: meta}}
        end
      end
    end
  end

  # Info-document requests (currently only IIIF Image API 3.0
  # `info.json`). Loads the source long enough to read its
  # dimensions, builds the JSON document, and sends it as
  # `application/ld+json` per the IIIF spec. No transform happens —
  # the source bytes are not encoded into the response.
  defp run_info(conn, :iiif_image_info, source, options) do
    with {:ok, image, _meta} <-
           wrap(options.source_resolver.load(source, options.source_resolver_options)) do
      width = Image.width(image)
      height = Image.height(image)
      id = canonical_iiif_id(conn)
      doc = Image.Plug.Provider.IIIF.InfoJson.build(id, {width, height})
      body = :json.encode(doc) |> IO.iodata_to_binary()

      conn
      |> Plug.Conn.put_resp_content_type("application/ld+json")
      |> Plug.Conn.put_resp_header("link", iiif_profile_link())
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=86400")
      |> Plug.Conn.send_resp(200, body)
      |> then(&{:ok, &1})
    end
  end

  # The IIIF spec wants the `id` to be the canonical URL of the
  # image service — i.e. the request URL with `/info.json` stripped.
  defp canonical_iiif_id(%Plug.Conn{} = conn) do
    full = Plug.Conn.request_url(conn)
    String.replace_suffix(full, "/info.json", "")
  end

  # Per IIIF Image API 3.0 §6, servers SHOULD include a `Link`
  # header pointing to the profile URI in info.json responses.
  defp iiif_profile_link do
    ~s(<http://iiif.io/api/image/3/level2.json>;rel="profile")
  end

  # Lifts `{:ok, ...}` and `{:error, %Error{}}` into the
  # `{:error, error, nil}` shape used by `respond_error/4` for
  # errors that occur before the source is loaded.
  defp wrap({:ok, _} = ok), do: ok
  defp wrap({:ok, _, _} = ok), do: ok
  defp wrap({:ok, _, _, _} = ok), do: ok
  defp wrap({:error, %Error{} = error}), do: {:error, error, nil}

  defp wrap_unit(:ok), do: :ok
  defp wrap_unit({:error, %Error{} = error}), do: {:error, error, nil}

  # Verifies the request signature when the plug is configured with
  # `:signing`. Returns `:ok` when no signing config is present (the
  # default), when a valid signature is supplied, or when signatures
  # are not required and none was supplied.
  defp verify_signature(_conn, %{signing: nil}), do: :ok

  defp verify_signature(%Plug.Conn{} = conn, %{signing: %{keys: keys} = signing}) do
    Image.Plug.Signing.verify(
      request_path_with_query(conn),
      keys,
      required?: Map.get(signing, :required?, false)
    )
  end

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: ""}), do: path

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: q}),
    do: "#{path}?#{q}"

  defp run_encode(conn, normalised, image, meta, options, cache) do
    interpreter_options = [resolve_layer_source: layer_source_resolver(options)]

    encode_options = [
      source_content_type: meta.content_type,
      accept: accept_header(conn)
    ]

    with {:ok, transformed} <-
           Pipeline.Interpreter.execute(normalised, image, interpreter_options),
         {:ok, body, content_type, extra_headers} <-
           normalise_encode(
             Pipeline.Encoder.encode(transformed, normalised.output, encode_options)
           ) do
      {:ok, send_body(conn, body, content_type, extra_headers, cache)}
    end
  end

  # Picks the format the encoder will actually emit, used to compute
  # a cache key that differs across negotiated outputs. Mirrors the
  # encoder's own selection logic.
  defp chosen_format(
         %Pipeline{output: %Image.Plug.Pipeline.Ops.Format{type: :auto}},
         accept,
         meta
       ) do
    cond do
      Image.Plug.Capabilities.avif_write?() and is_binary(accept) and
          String.contains?(accept, "image/avif") ->
        :avif

      is_binary(accept) and
          (String.contains?(accept, "image/webp") or String.contains?(accept, "image/*") or
             String.contains?(accept, "*/*")) ->
        :webp

      true ->
        case Map.get(meta, :content_type, "image/jpeg") do
          "image/png" -> :png
          "image/webp" -> :webp
          "image/avif" -> :avif
          _ -> :jpeg
        end
    end
  end

  defp chosen_format(
         %Pipeline{output: %Image.Plug.Pipeline.Ops.Format{type: type}},
         _accept,
         _meta
       ),
       do: type

  defp normalise_encode({:ok, body, content_type}), do: {:ok, body, content_type, []}

  defp normalise_encode({:ok, body, content_type, headers}),
    do: {:ok, body, content_type, headers}

  defp normalise_encode({:error, _} = error), do: error

  defp accept_header(conn) do
    case Plug.Conn.get_req_header(conn, "accept") do
      [value | _] -> value
      [] -> nil
    end
  end

  # Closure passed to the interpreter so a `Draw` op can resolve its
  # nested `%Source{}`s using the same source resolver pipeline as
  # the base image. Returns `{:ok, %Vix.Vips.Image{}}` or
  # `{:error, _}`.
  defp layer_source_resolver(options) do
    fn source ->
      case options.source_resolver.load(source, options.source_resolver_options) do
        {:ok, image, _meta} -> {:ok, image}
        {:error, _} = error -> error
      end
    end
  end

  defp resolve({:pipeline, pipeline, source}, _options) do
    {:ok, pipeline, source}
  end

  defp resolve({:passthrough, source}, _options) do
    # Passthrough still runs through the interpreter (a no-op pass)
    # and the encoder, so a downstream cache sees a consistent
    # response shape regardless of whether the URL carried any
    # transforms. The encoder doesn't honour `Format{type: :auto}`
    # without an explicit `Accept` negotiation context, so we
    # substitute `:jpeg` here.
    pipeline =
      Pipeline.new(provider: Image.Plug.Provider.Cloudflare)
      |> Pipeline.put_output(%Image.Plug.Pipeline.Ops.Format{type: :jpeg, quality: 85})

    {:ok, pipeline, source}
  end

  defp resolve({:variant, name, overrides, source}, options) do
    case options.variant_store.get(name, options.variant_store_options) do
      {:ok, variant} ->
        merged = apply_variant_overrides(variant.pipeline, overrides)
        {:ok, merged, source}

      {:error, :not_found} ->
        {:error, Error.new(:variant_not_found, "no such variant", details: %{name: name})}
    end
  end

  # Per-request overrides arrive as a keyword list of
  # `Image.Plug.Pipeline` field replacements. The override shape
  # we currently honour is `{:output, %Ops.Format{}}` to swap the
  # output format. More override shapes land alongside the providers
  # that emit them.
  defp apply_variant_overrides(pipeline, []), do: pipeline

  defp apply_variant_overrides(pipeline, overrides) when is_list(overrides) do
    Enum.reduce(overrides, pipeline, fn
      {:output, %Image.Plug.Pipeline.Ops.Format{} = format}, acc ->
        Image.Plug.Pipeline.put_output(acc, format)

      {:on_error, value}, acc ->
        %{acc | on_error: value}

      _other, acc ->
        acc
    end)
  end

  defp send_body(conn, {:stream, stream}, content_type, extra_headers, cache) do
    conn
    |> put_cache_headers(cache)
    |> put_extra_headers(extra_headers)
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_chunked(200)
    |> stream_chunks(stream)
  end

  defp send_body(conn, {:bytes, bytes}, content_type, extra_headers, cache) do
    conn
    |> put_cache_headers(cache)
    |> put_extra_headers(extra_headers)
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_resp(200, bytes)
  end

  defp send_not_modified(conn, cache) do
    conn
    |> put_cache_headers(cache)
    |> Plug.Conn.send_resp(304, "")
  end

  defp put_cache_headers(conn, cache) do
    conn
    |> Plug.Conn.put_resp_header("etag", cache.etag)
    |> Plug.Conn.put_resp_header("cache-control", cache.cache_control)
    |> put_vary(cache)
    |> put_last_modified(cache)
  end

  defp put_vary(conn, %{vary: [_ | _] = vary}) do
    Plug.Conn.put_resp_header(conn, "vary", Enum.join(vary, ", "))
  end

  defp put_last_modified(conn, %{last_modified: %DateTime{} = ts}) do
    Plug.Conn.put_resp_header(conn, "last-modified", format_http_date(ts))
  end

  defp put_last_modified(conn, _cache), do: conn

  defp format_http_date(%DateTime{} = ts) do
    # RFC 7231 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT"
    Calendar.strftime(ts, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp put_extra_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_resp_header(acc, key, value)
    end)
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn chunk, acc ->
      case Plug.Conn.chunk(acc, chunk) do
        {:ok, acc} ->
          {:cont, acc}

        {:error, :closed} ->
          {:halt, acc}

        {:error, reason} ->
          Logger.warning("image_plug: stream chunk failed: #{inspect(reason)}")
          {:halt, acc}
      end
    end)
  end

  defp respond_error(conn, %Error{} = error, options, context) do
    log_error(error)

    case resolved_on_error(options.on_error) do
      :raise ->
        raise "image_plug: #{error.tag}: #{error.message}"

      :fallback_to_source ->
        case context do
          %{image: image, meta: meta} ->
            send_fallback_source(conn, error, image, meta)

          _ ->
            send_status_error(conn, error)
        end

      :render_error_image ->
        send_error_image(conn, error)

      :status_text ->
        send_status_error(conn, error)

      {:status, code} when is_integer(code) ->
        send_status_error(conn, %{error | tag: error.tag}, code)
    end
  end

  defp resolved_on_error(:auto) do
    env =
      Application.get_env(:image_plug, :env) ||
        (Code.ensure_loaded?(Mix) && function_exported?(Mix, :env, 0) && apply(Mix, :env, []))

    if env == :prod, do: :fallback_to_source, else: :render_error_image
  end

  defp resolved_on_error(other), do: other

  defp send_status_error(conn, error, status \\ nil) do
    status = status || Error.status(error)
    body = "image_plug: #{error.tag}: #{error.message}"

    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.put_resp_header("x-image-plug-error", to_string(error.tag))
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(status, body)
  end

  defp send_fallback_source(conn, error, image, meta) do
    case Pipeline.Encoder.encode(image, source_format(meta), buffer: :bytes) do
      {:ok, {:bytes, bytes}, content_type} ->
        conn
        |> Plug.Conn.put_resp_content_type(content_type)
        |> Plug.Conn.put_resp_header("x-image-plug-error", to_string(error.tag))
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
        |> Plug.Conn.send_resp(200, bytes)

      _ ->
        send_status_error(conn, error)
    end
  end

  defp source_format(meta) do
    type =
      case Map.get(meta, :content_type) do
        "image/png" -> :png
        "image/webp" -> :webp
        "image/avif" -> :avif
        _ -> :jpeg
      end

    %Image.Plug.Pipeline.Ops.Format{type: type, quality: 85, metadata: :keep}
  end

  defp send_error_image(conn, error) do
    body = render_error_placeholder(error)

    conn
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.put_resp_header("x-image-plug-error", to_string(error.tag))
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(200, body)
  end

  # Renders a simple PNG placeholder (400×300) with the error tag and
  # message painted onto a high-contrast background. Built via SVG so
  # we don't drag in font dependencies or layout libraries.
  defp render_error_placeholder(%Error{tag: tag, message: message}) do
    svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="400" height="300">
      <rect width="100%" height="100%" fill="#fde2e2"/>
      <rect x="2" y="2" width="396" height="296" fill="none" stroke="#b71c1c" stroke-width="4"/>
      <text x="20" y="60" font-family="sans-serif" font-size="22" fill="#b71c1c" font-weight="700">image_server error</text>
      <text x="20" y="100" font-family="monospace" font-size="16" fill="#7f1010">#{tag}</text>
      <text x="20" y="140" font-family="sans-serif" font-size="14" fill="#7f1010">#{escape_xml(message)}</text>
    </svg>
    """

    case Image.from_svg(svg) do
      {:ok, image} ->
        case Image.write(image, :memory, suffix: ".png") do
          {:ok, bytes} -> bytes
          {:error, _} -> fallback_error_bytes()
        end

      {:error, _} ->
        fallback_error_bytes()
    end
  rescue
    _ -> fallback_error_bytes()
  end

  defp escape_xml(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.slice(0, 120)
  end

  defp fallback_error_bytes do
    # 1×1 transparent PNG used when even the SVG placeholder fails.
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1,
      13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp log_error(%Error{} = error) do
    Logger.error(fn ->
      "image_plug request failed: tag=#{error.tag} message=#{error.message} " <>
        "details=#{inspect(error.details)}"
    end)
  end

  # ---------- public helpers (formerly Image.Server top-level) ----------

  @version Mix.Project.config()[:version]

  @doc """
  Returns the library version as a string.

  ### Returns

  * A semver-like version string such as `"0.1.0-dev"`.

  ### Examples

      iex> is_binary(Image.Plug.version())
      true

  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Returns the default telemetry prefix used by the request plug.

  ### Returns

  * The list of atoms `[:image_plug]`.

  ### Examples

      iex> Image.Plug.default_telemetry_prefix()
      [:image_plug]

  """
  @spec default_telemetry_prefix() :: [atom(), ...]
  def default_telemetry_prefix, do: [:image_plug]

  alias Image.Plug.{Pipeline, Variant}

  @default_store Image.Plug.VariantStore.ETS

  @doc """
  Inserts or updates a variant.

  ### Arguments

  * `name_or_variant` is either a variant name string or a complete
    `Image.Plug.Variant` struct.

  * When the first argument is a name, the second argument is either
    a Cloudflare-style options string, an `Image.Plug.Pipeline`
    struct, or a `{provider_module, options_string}` tuple.

  ### Options

  * `:store` — `{module, options}` tuple identifying the store.
    Defaults to `{Image.Plug.VariantStore.ETS, []}`.

  * `:metadata` — arbitrary metadata map stored on the variant.

  * `:never_require_signed_urls?` — boolean, defaults to `false`.

  ### Returns

  * `{:ok, variant}` on success.

  * `{:error, reason}` on failure (e.g. invalid options string).

  """
  @spec put_variant(Variant.t() | String.t(), term(), keyword()) ::
          {:ok, Variant.t()} | {:error, term()}
  def put_variant(name_or_variant, definition_or_options \\ [], options \\ [])

  def put_variant(%Variant{} = variant, options, _ignored) when is_list(options) do
    {store, store_options} = store(options)
    store.put(variant, Keyword.merge(store_options, Keyword.take(options, [:server, :table])))
  end

  def put_variant(name, definition, options) when is_binary(name) do
    case to_variant(name, definition, options) do
      {:ok, variant} -> put_variant(variant, options, [])
      {:error, _} = error -> error
    end
  end

  @doc """
  Fetches a variant by name.

  Returns `{:ok, variant}` or `{:error, :not_found}`.

  ### Examples

      iex> case Image.Plug.get_variant("public") do
      ...>   {:ok, variant} -> variant.name
      ...>   {:error, _} -> nil
      ...> end
      "public"

  """
  @spec get_variant(String.t(), keyword()) ::
          {:ok, Variant.t()} | {:error, :not_found}
  def get_variant(name, options \\ []) when is_binary(name) do
    {store, store_options} = store(options)
    store.get(name, Keyword.merge(store_options, Keyword.take(options, [:table])))
  end

  @doc """
  Deletes a variant by name.

  ### Returns

  * `:ok` on success.

  * `{:error, :not_found}` if the variant does not exist.

  """
  @spec delete_variant(String.t(), keyword()) :: :ok | {:error, :not_found}
  def delete_variant(name, options \\ []) when is_binary(name) do
    {store, store_options} = store(options)
    store.delete(name, Keyword.merge(store_options, Keyword.take(options, [:server])))
  end

  @doc """
  Lists every variant in the store.

  ### Returns

  * `{:ok, [variant]}` — the order is store-defined (the default ETS
    store sorts by name).

  """
  @spec list_variants(keyword()) :: {:ok, [Variant.t()]}
  def list_variants(options \\ []) do
    {store, store_options} = store(options)
    store.list(Keyword.merge(store_options, Keyword.take(options, [:table])))
  end

  defp store(options) do
    case Keyword.get(options, :store, {@default_store, []}) do
      module when is_atom(module) -> {module, []}
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
    end
  end

  defp to_variant(name, %Pipeline{} = pipeline, options) do
    {:ok,
     %Variant{
       name: name,
       pipeline: pipeline,
       options: nil,
       metadata: Keyword.get(options, :metadata, %{}),
       never_require_signed_urls?: Keyword.get(options, :never_require_signed_urls?, false)
     }}
  end

  defp to_variant(name, options_string, options) when is_binary(options_string) do
    to_variant(name, {Image.Plug.Provider.Cloudflare, options_string}, options)
  end

  defp to_variant(name, {provider, options_string}, options)
       when is_atom(provider) and is_binary(options_string) do
    case parse_with(provider, options_string) do
      {:ok, pipeline} ->
        {:ok,
         %Variant{
           name: name,
           pipeline: pipeline,
           options: options_string,
           metadata: Keyword.get(options, :metadata, %{}),
           never_require_signed_urls?: Keyword.get(options, :never_require_signed_urls?, false)
         }}

      {:error, _} = error ->
        error
    end
  end

  defp to_variant(_name, other, _options) do
    {:error,
     Image.Plug.Error.new(
       :invalid_option,
       "variant definition must be an options string, a Pipeline, or a {provider, string} tuple",
       details: %{got: inspect(other)}
     )}
  end

  defp parse_with(Image.Plug.Provider.Cloudflare, options_string) do
    Image.Plug.Provider.Cloudflare.Options.parse(options_string)
  end

  defp parse_with(provider, _options_string) do
    {:error,
     Image.Plug.Error.new(
       :invalid_option,
       "no options-string parser registered for provider",
       details: %{provider: provider}
     )}
  end
end
