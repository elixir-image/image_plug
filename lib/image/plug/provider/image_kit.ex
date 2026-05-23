defmodule Image.Plug.Provider.ImageKit do
  @moduledoc """
  ImageKit URL provider.

  Wires `Image.Plug.Provider.ImageKit.URL` (URL recognition),
  `Image.Plug.Provider.ImageKit.Signing` (optional HMAC verification),
  and `Image.Plug.Provider.ImageKit.Options` (option parsing) into
  the `Image.Plug.Provider` behaviour.

  Mount under any path (typically the root of an imagekit-style
  domain or behind a per-account endpoint segment).

  ### Options

  * `:mount` — string path prefix the plug is mounted under.
    Stripped before processing. Defaults to `""`.

  * `:endpoint` — additional path prefix to strip after `:mount`.
    ImageKit URLs commonly include a per-account endpoint segment
    (e.g. `/your_imagekit_id/`). Defaults to `""`.

  * `:strict?` — `true` (default) rejects unknown ImageKit option
    keys with `:unknown_option`. `false` logs and ignores them.

  * `:signing` — `nil` (default; no signing) or
    `%{keys: [...], required?: bool}`. When set, every request URL
    must carry a valid `?ik-s=<hex>` parameter. Wire format matches
    ImageKit's hosted signed URLs (HMAC-SHA1, hex-encoded). See
    `Image.Plug.Provider.ImageKit.Signing`.

  ### URL forms recognised

  * `<mount>/<endpoint>/tr:<transforms>/<source>` — path-prefix
    transforms.

  * `<mount>/<endpoint>/<source>?tr=<transforms>` — query-string
    transforms.

  ### Conformance

  See `guides/image_kit_conformance.md` for the per-option support
  matrix and the documented gaps.
  """

  @behaviour Image.Plug.Provider

  alias Image.Plug.Error
  alias Image.Plug.Provider.ImageKit.{Options, Signing, URL}

  @impl Image.Plug.Provider
  def parse(%Plug.Conn{} = conn, options) when is_list(options) do
    with :ok <- verify_signature(conn, options),
         {:ok, parsed} <-
           URL.parse(conn, Keyword.take(options, [:mount, :endpoint])),
         {:ok, pipeline} <-
           Options.parse(parsed.options, Keyword.take(options, [:strict?])) do
      result =
        cond do
          pipeline.ops != [] -> {:pipeline, pipeline, parsed.source}
          parsed.options != "" -> {:pipeline, pipeline, parsed.source}
          true -> {:passthrough, parsed.source}
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
           "imagekit :signing must be nil or %{keys: [...], required?: bool}",
           details: %{got: inspect(other)}
         )}
    end
  end

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: ""}), do: path

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: q}),
    do: "#{path}?#{q}"
end
