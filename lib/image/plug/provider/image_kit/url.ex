defmodule Image.Plug.Provider.ImageKit.URL do
  @moduledoc """
  URL-shape recognition for the [ImageKit URL grammar](https://imagekit.io/docs/transformations).

  ImageKit supports two URL forms; both are recognised:

  * **Path-prefix** (default and most common):

        <host>/<endpoint>/tr:<transforms>/<source>

    where `<transforms>` is a comma-separated list of `key-value`
    pairs (e.g. `w-200,h-100,q-80`). Multi-stage chained transforms
    use `:` as the stage separator: `tr:w-200,h-100:rt-90`.

  * **Query-string**:

        <host>/<endpoint>/<source>?tr=<transforms>

  Both forms are equivalent on inbound. v0.1 flattens multi-stage
  chained transforms by joining stages with `,` (the canonical IR
  doesn't model chained transforms).
  """

  alias Image.Plug.{Error, Source}

  @typedoc """
  The recognised URL shape.
  """
  @type recognised :: %{
          shape: :image_kit,
          options: String.t(),
          source: Source.t()
        }

  @doc """
  Parses the request path of a `Plug.Conn` into a recognised URL shape.

  ### Arguments

  * `conn` is a `Plug.Conn` struct.

  * `options` is a keyword list. The following keys are honoured:

  ### Options

  * `:mount` — string path prefix the plug is mounted under.
    Stripped before processing. Defaults to `""`.

  * `:endpoint` — additional path prefix to strip after `:mount`.
    ImageKit URLs commonly include a per-account endpoint segment
    (e.g. `/your_imagekit_id/`). Defaults to `""`.

  ### Returns

  * `{:ok, recognised}` on a successful match.

  * `{:error, %Image.Plug.Error{tag: :malformed_url}}` when the path
    doesn't sit under the configured mount/endpoint or has no
    source segment.

  ### Examples

      iex> conn = %Plug.Conn{
      ...>   path_info: ["tr:w-200,h-100", "sample.jpg"],
      ...>   request_path: "/tr:w-200,h-100/sample.jpg",
      ...>   query_string: ""
      ...> }
      iex> {:ok, parsed} = Image.Plug.Provider.ImageKit.URL.parse(conn, [])
      iex> parsed.options
      "w-200,h-100"
      iex> parsed.source.ref
      "/sample.jpg"

  """
  @spec parse(Plug.Conn.t(), keyword()) :: {:ok, recognised()} | {:error, Error.t()}
  def parse(%Plug.Conn{path_info: path_info, query_string: query_string}, options)
      when is_list(options) do
    mount_segments = mount_segments(Keyword.get(options, :mount, ""))
    endpoint_segments = mount_segments(Keyword.get(options, :endpoint, ""))
    decoded = Enum.map(path_info, &URI.decode/1)

    with {:ok, after_mount} <- strip_prefix(decoded, mount_segments, "mount"),
         {:ok, after_endpoint} <- strip_prefix(after_mount, endpoint_segments, "endpoint") do
      {:ok, {transforms_string, source_segments}} = extract_transforms(after_endpoint, query_string)

      case source_segments do
        [] ->
          {:error, Error.new(:malformed_url, "imagekit request has no source segment")}

        _ ->
          with {:ok, source} <- build_source(source_segments) do
            {:ok,
             %{
               shape: :image_kit,
               options: transforms_string,
               source: source
             }}
          end
      end
    end
  end

  defp mount_segments(""), do: []

  defp mount_segments(value) when is_binary(value) do
    value
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
       Error.new(:malformed_url, "request path does not sit under the configured #{label}")}
    end
  end

  # Two valid shapes: a leading `tr:...` segment, OR a `?tr=...`
  # query parameter (which may coexist with the leading segment).
  defp extract_transforms(path_segments, query_string) do
    {leading_transforms, remaining} =
      case path_segments do
        ["tr:" <> rest | tail] -> {flatten_chained(rest), tail}
        _ -> {nil, path_segments}
      end

    {:ok, query_transforms} = extract_query_transforms(query_string)

    joined =
      [leading_transforms, query_transforms]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(",")

    {:ok, {joined, remaining}}
  end

  # Multi-stage transforms separated by `:` (e.g. `w-200,h-100:rt-90`).
  # v0.1 flattens by joining stages with `,`.
  defp flatten_chained(transforms) do
    transforms
    |> String.split(":", trim: true)
    |> Enum.join(",")
  end

  defp extract_query_transforms(""), do: {:ok, ""}

  defp extract_query_transforms(query_string) when is_binary(query_string) do
    query_string
    |> URI.decode_query()
    |> Map.fetch("tr")
    |> case do
      {:ok, value} -> {:ok, flatten_chained(value)}
      :error -> {:ok, ""}
    end
  end

  defp build_source([single]) do
    cond do
      String.starts_with?(single, "http://") or String.starts_with?(single, "https://") ->
        Source.url(single)

      true ->
        Source.path("/" <> single)
    end
  end

  defp build_source(segments) when is_list(segments) do
    Source.path("/" <> Enum.join(segments, "/"))
  end
end
