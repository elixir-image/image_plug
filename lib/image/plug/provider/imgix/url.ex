defmodule Image.Plug.Provider.Imgix.URL do
  @moduledoc """
  URL-shape recognition for the [imgix URL grammar](https://docs.imgix.com/en/latest/setup/serving-images).

  Two source modes per imgix's documentation:

  * **Web folder source**: the path *is* the source key
    (`/photos/sunset.jpg`). The host's `Image.Plug.SourceResolver`
    (typically `File` or `Hosted`) maps the path to bytes.

  * **Web proxy source**: the path is a percent-encoded absolute
    URL (`/https%3A%2F%2Fassets.example.com%2Fsunset.jpg`).
    Treated as a `:url` source; resolved by
    `Image.Plug.SourceResolver.HTTP`.

  Unlike Cloudflare, imgix has no path marker — every request
  under the configured mount is presumed to be a transform request.
  Options come from the query string, not the path.
  """

  alias Image.Plug.{Error, Source}

  @typedoc """
  The recognised URL shape.
  """
  @type recognised :: %{
          shape: :imgix,
          options: String.t(),
          source: Source.t()
        }

  @doc """
  Parses the request path of a `Plug.Conn` into a recognised URL
  shape.

  ### Arguments

  * `conn` is a `Plug.Conn` struct.

  * `options` is a keyword list. The following keys are honoured:

  ### Options

  * `:mount` — string path prefix the plug is mounted under.
    Stripped before treating the rest as the source path. Defaults
    to `""`.

  ### Returns

  * `{:ok, recognised}` on a successful match.

  * `{:error, %Image.Plug.Error{tag: :malformed_url}}` when the
    path does not sit under the configured mount.

  * `{:error, %Image.Plug.Error{tag: :invalid_option}}` when the
    decoded source is malformed (e.g. relative path, unparseable
    URL).

  ### Examples

      iex> conn = %Plug.Conn{
      ...>   path_info: ["photos", "sunset.jpg"],
      ...>   request_path: "/photos/sunset.jpg",
      ...>   query_string: "w=200&fit=crop"
      ...> }
      iex> {:ok, %{shape: :imgix, options: "w=200&fit=crop", source: source}} =
      ...>   Image.Plug.Provider.Imgix.URL.parse(conn, [])
      iex> source.kind
      :path
      iex> source.ref
      "/photos/sunset.jpg"

  """
  @spec parse(Plug.Conn.t(), keyword()) :: {:ok, recognised()} | {:error, Error.t()}
  def parse(%Plug.Conn{path_info: path_info, query_string: query_string}, options)
      when is_list(options) do
    mount_segments = mount_segments(Keyword.get(options, :mount, ""))
    decoded = Enum.map(path_info, &URI.decode/1)

    case strip_prefix(decoded, mount_segments) do
      {:ok, []} ->
        {:error, Error.new(:malformed_url, "imgix request has no source path")}

      {:ok, segments} ->
        with {:ok, source} <- build_source(segments) do
          {:ok, %{shape: :imgix, options: query_string, source: source}}
        end

      :error ->
        {:error,
         Error.new(:malformed_url, "request path does not sit under the configured mount")}
    end
  end

  defp mount_segments(""), do: []

  defp mount_segments(mount) when is_binary(mount) do
    mount
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> String.split("/", trim: true)
  end

  defp strip_prefix(path_info, []), do: {:ok, path_info}

  defp strip_prefix(path_info, mount_segments) do
    if List.starts_with?(path_info, mount_segments) do
      {:ok, Enum.drop(path_info, length(mount_segments))}
    else
      :error
    end
  end

  defp build_source([first | _rest] = segments) do
    cond do
      # A single segment that decodes to an http(s) URL is a web
      # proxy source. Imgix's convention is to percent-encode the
      # entire URL into one path segment.
      length(segments) == 1 and
          (String.starts_with?(first, "http://") or String.starts_with?(first, "https://")) ->
        Source.url(first)

      true ->
        Source.path("/" <> Enum.join(segments, "/"))
    end
  end
end
