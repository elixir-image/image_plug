defmodule Image.Plug.Provider.Imgix do
  @moduledoc """
  Imgix URL provider.

  Wires `Image.Plug.Provider.Imgix.URL` (URL recognition),
  `Image.Plug.Provider.Imgix.Signing` (optional HMAC verification),
  and `Image.Plug.Provider.Imgix.Options` (option parsing) into the
  `Image.Plug.Provider` behaviour.

  Mount under any path (typically the root of an imgix-style
  subdomain). Every request under the mount is treated as a
  transform request whose options come from the query string.

  ### Options

  * `:mount` — string path prefix the plug is mounted under.
    Stripped before treating the rest as the source path. Defaults
    to `""`.

  * `:strict?` — `true` (default) rejects unknown imgix option
    keys with `:unknown_option`. `false` logs and ignores them.

  * `:signing` — `nil` (default; no signing) or
    `%{keys: [...], required?: bool}`. When set, every request
    URL must carry a valid `?s=<hex>` parameter. Wire format
    matches imgix's hosted signed URLs. See
    `Image.Plug.Provider.Imgix.Signing`.

  ### URL forms recognised

  * `<mount>/<source-path>?<options>` — web-folder source.

  * `<mount>/<percent-encoded-https-url>?<options>` — web-proxy
    source.

  ### Conformance

  See `guides/imgix_conformance.md` for the per-option support
  matrix and the documented gaps.
  """

  @behaviour Image.Plug.Provider

  alias Image.Plug.Error
  alias Image.Plug.Provider.Imgix.{Options, Signing, URL}

  @impl Image.Plug.Provider
  def parse(%Plug.Conn{} = conn, options) when is_list(options) do
    with :ok <- verify_signature(conn, options),
         {:ok, %{shape: :imgix, options: query_string, source: source}} <-
           URL.parse(conn, Keyword.take(options, [:mount])),
         {:ok, pipeline} <- Options.parse(query_string, Keyword.take(options, [:strict?])) do
      result =
        cond do
          pipeline.ops != [] -> {:pipeline, pipeline, source}
          non_default_output?(pipeline.output) -> {:pipeline, pipeline, source}
          true -> {:passthrough, source}
        end

      {:ok, result}
    end
  end

  defp verify_signature(conn, options) do
    case Keyword.get(options, :signing) do
      nil ->
        :ok

      %{keys: [_ | _] = keys} = signing ->
        Signing.verify(
          request_path_with_query(conn),
          keys,
          required?: Map.get(signing, :required?, false)
        )

      other ->
        {:error,
         Error.new(
           :invalid_option,
           "imgix :signing must be nil or %{keys: [...], required?: bool}",
           details: %{got: inspect(other)}
         )}
    end
  end

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: ""}), do: path

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: q}),
    do: "#{path}?#{q}"

  # The default Format struct represents "no output options set".
  # Anything else means the request asked for a specific format,
  # quality, metadata policy, etc. — even if no transform ops were
  # parsed — and we should run through the encoder rather than
  # passthrough.
  defp non_default_output?(%Image.Plug.Pipeline.Ops.Format{} = format) do
    format != %Image.Plug.Pipeline.Ops.Format{}
  end
end
