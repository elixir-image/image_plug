defmodule Image.Plug.Provider.Cloudinary do
  @moduledoc """
  Cloudinary URL provider.

  Wires `Image.Plug.Provider.Cloudinary.URL` (URL recognition),
  `Image.Plug.Provider.Cloudinary.Signing` (optional HMAC verification),
  and `Image.Plug.Provider.Cloudinary.Options` (option parsing) into
  the `Image.Plug.Provider` behaviour.

  Mount under any path. The expected URL shape is:

      <mount>/<account>/image/<delivery>/[s--<sig>--/]<transforms>/<source>

  where `<transforms>` may be a single comma-separated stage or
  multiple stages joined with `/` (v0.1 flattens multiple stages
  into one).

  ### Options

  * `:mount` — string path prefix the plug is mounted under.
    Stripped before treating the rest as the cloudinary path.
    Defaults to `""`.

  * `:account` — when set, asserts the URL's account segment
    matches this value. When `nil` (default), any account is
    accepted.

  * `:strict?` — `true` (default) rejects unknown cloudinary option
    keys with `:unknown_option`. `false` logs and ignores them.

  * `:signing` — `nil` (default; no signing) or
    `%{keys: [...], required?: bool}`. When set, every request URL
    must carry a valid `s--<sig>--` segment. Wire format matches
    Cloudinary's hosted signed URLs (SHA-256, 32 url-safe-base64
    characters). See `Image.Plug.Provider.Cloudinary.Signing`.

  ### Conformance

  See `guides/cloudinary_conformance.md` for the per-option support
  matrix and the documented gaps.
  """

  @behaviour Image.Plug.Provider

  alias Image.Plug.Error
  alias Image.Plug.Provider.Cloudinary.{Options, Signing, URL}

  @impl Image.Plug.Provider
  def parse(%Plug.Conn{} = conn, options) when is_list(options) do
    with :ok <- verify_signature(conn, options),
         {:ok, parsed} <-
           URL.parse(conn, Keyword.take(options, [:mount, :account])),
         {:ok, pipeline} <-
           Options.parse(parsed.options, Keyword.take(options, [:strict?])) do
      # Run through the encoder whenever the URL carried any
      # transform options at all — even ones that produced no ops
      # (e.g. `f_auto` alone). Passthrough only when the URL had no
      # options string and no parsed ops.
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
         Error.new(:invalid_option,
           "cloudinary :signing must be nil or %{keys: [...], required?: bool}",
           details: %{got: inspect(other)}
         )}
    end
  end

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: q}), do: "#{path}?#{q}"
end
