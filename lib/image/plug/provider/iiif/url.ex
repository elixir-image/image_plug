defmodule Image.Plug.Provider.IIIF.URL do
  @moduledoc """
  Recognises [IIIF Image API 3.0](https://iiif.io/api/image/3.0/)
  URL forms in `Plug.Conn.path_info` and returns a structured result
  the higher-level provider dispatches on.

  Two forms are recognised:

  * `<mount>/<endpoint>/<identifier>/info.json` — the IIIF discovery
    document. Tagged `:info_json` in the result; the provider routes
    these to the `Format{type: :json}` encoder path.

  * `<mount>/<endpoint>/<identifier>/<region>/<size>/<rotation>/<quality>.<format>`
    — the standard image URL. Tagged `:image`; the provider hands the
    five option segments to `Image.Plug.Provider.IIIF.Options.parse/2`.

  ### Configuration

  * `:mount` — string path prefix this plug is mounted under;
    stripped before parsing. Defaults to `""`.

  * `:endpoint` — the IIIF version-prefix segment (e.g. `"iiif/3"`,
    `"image"`, or `""` for servers that publish at the mount root).
    Defaults to `"iiif/3"`.
  """

  alias Image.Plug.{Error, Source}

  @typedoc """
  The recognised URL shape.

  * `:kind` is `:image` or `:info_json`.

  * `:source` is the resolved `Image.Plug.Source` for the asset.

  * `:options_segments` (only for `:kind == :image`) is the four-tuple
    `{region, size, rotation, quality_dot_format}` extracted from the
    URL — left to `Image.Plug.Provider.IIIF.Options.parse/2` to decode.
  """
  @type recognised :: %{
          required(:kind) => :image | :info_json,
          required(:source) => Source.t(),
          optional(:options_segments) => {String.t(), String.t(), String.t(), String.t()}
        }

  @doc """
  Parses the request path into a recognised IIIF URL shape.

  ### Arguments

  * `conn` is a `Plug.Conn`. Only `path_info` is read.

  * `options` is a keyword list — see the Options section.

  ### Options

  * `:mount` — see the moduledoc.

  * `:endpoint` — see the moduledoc.

  ### Returns

  * `{:ok, recognised}` on a successful match.

  * `{:error, %Image.Plug.Error{}}` when the path doesn't match any
    IIIF form.

  ### Examples

      iex> conn = %Plug.Conn{path_info: ["iiif", "3", "cat.jpg", "full", "max", "0", "default.jpg"]}
      iex> {:ok, parsed} = Image.Plug.Provider.IIIF.URL.parse(conn, [])
      iex> parsed.kind
      :image

      iex> conn = %Plug.Conn{path_info: ["iiif", "3", "cat.jpg", "info.json"]}
      iex> {:ok, parsed} = Image.Plug.Provider.IIIF.URL.parse(conn, [])
      iex> parsed.kind
      :info_json

  """
  @spec parse(Plug.Conn.t(), keyword()) :: {:ok, recognised()} | {:error, Error.t()}
  def parse(%Plug.Conn{path_info: path_info}, options) when is_list(options) do
    mount_segments = split_path(Keyword.get(options, :mount, ""))
    endpoint_segments = split_path(Keyword.get(options, :endpoint, "iiif/3"))

    decoded = Enum.map(path_info, &URI.decode/1)

    with {:ok, after_mount} <- strip_prefix(decoded, mount_segments, "mount"),
         {:ok, after_endpoint} <- strip_prefix(after_mount, endpoint_segments, "endpoint") do
      dispatch(after_endpoint)
    end
  end

  # `<id>/info.json` — discovery document.
  defp dispatch([identifier, "info.json"]) do
    with {:ok, source} <- build_source(identifier) do
      {:ok, %{kind: :info_json, source: source}}
    end
  end

  # `<id>/<region>/<size>/<rotation>/<quality>.<format>` — the
  # standard image URL with all five option segments present.
  defp dispatch([identifier, region, size, rotation, quality_dot_format]) do
    with {:ok, source} <- build_source(identifier) do
      {:ok,
       %{
         kind: :image,
         source: source,
         options_segments: {region, size, rotation, quality_dot_format}
       }}
    end
  end

  defp dispatch([_identifier]) do
    # Bare identifier — the spec mandates a 303 redirect to info.json.
    # Not yet implemented; reject with a hint.
    {:error,
     Error.new(:malformed_url,
       "IIIF bare-identifier requests should redirect to info.json (not yet implemented)"
     )}
  end

  defp dispatch(_segments) do
    {:error,
     Error.new(:malformed_url,
       "URL does not match any IIIF Image API 3.0 form"
     )}
  end

  # Identifiers in IIIF are URL-encoded; we already decoded the
  # whole path_info upstream, so the identifier here is the literal
  # logical path. `Image.Plug.Source.path/1` requires an absolute
  # path; identifiers without a leading `/` are treated as
  # relative-to-the-resolver-root.
  defp build_source(identifier) do
    case Source.path("/" <> identifier) do
      {:ok, _source} = ok -> ok
      {:error, _} = error -> error
    end
  end

  defp split_path(""), do: []

  defp split_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> String.split("/", trim: true)
  end

  defp strip_prefix(path_info, [], _label), do: {:ok, path_info}

  defp strip_prefix(path_info, segments, label) do
    if List.starts_with?(path_info, segments) do
      {:ok, Enum.drop(path_info, length(segments))}
    else
      {:error,
       Error.new(:malformed_url, "request path does not start with the configured #{label}",
         details: %{expected: segments, got: path_info}
       )}
    end
  end
end
