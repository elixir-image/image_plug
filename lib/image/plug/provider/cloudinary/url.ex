defmodule Image.Plug.Provider.Cloudinary.URL do
  @moduledoc """
  URL-shape recognition for the [Cloudinary delivery URL grammar](https://cloudinary.com/documentation/transformation_reference).

  Cloudinary URLs have the shape:

      <host>/<account>/<resource-type>/<delivery>/[<signature>/]<transforms>/<source>

  with:

  * `<account>` — the cloud name (e.g. `demo`).
  * `<resource-type>` — `image`, `video`, `raw`. v0.1 supports `image`.
  * `<delivery>` — `upload`, `fetch`, `private`, `authenticated`, `sprite`,
    `facebook`, etc. v0.1 recognises any value but only `upload` and
    `fetch` are exercised by tests.
  * `<signature>` — optional `s--<hex>--` segment for signed URLs.
  * `<transforms>` — zero or more comma-separated transform stages,
    each separated by `/`. v0.1 collapses multi-stage transforms by
    concatenating with commas; the canonical IR doesn't model chained
    transforms as v0.1.
  * `<source>` — the public id (with extension); for `delivery=fetch`
    it's a percent-encoded HTTPS URL.

  Unlike imgix and Cloudflare, Cloudinary embeds account + delivery
  segments in the path, so the recogniser strips them before reaching
  the source.
  """

  alias Image.Plug.{Error, Source}

  @signature_segment_re ~r/^s--[A-Za-z0-9_-]+--$/

  @typedoc """
  The recognised URL shape.

  * `:options` is the joined transform string (multiple stages comma-
    flattened) and may be empty.

  * `:source` is the resolved source.

  * `:account`, `:resource_type`, `:delivery`, `:signature` are the
    parsed path segments. Used by the wiring module to verify
    signatures and to reconstruct the canonical-string for HMAC
    verification.
  """
  @type recognised :: %{
          shape: :cloudinary,
          options: String.t(),
          source: Source.t(),
          account: String.t() | nil,
          resource_type: String.t(),
          delivery: String.t(),
          signature: String.t() | nil
        }

  @doc """
  Parses the request path of a `Plug.Conn` into a recognised URL shape.

  ### Arguments

  * `conn` is a `Plug.Conn` struct.

  * `options` is a keyword list. The following keys are honoured:

  ### Options

  * `:mount` — string path prefix the plug is mounted under. Stripped
    before treating the rest as the cloudinary path. Defaults to `""`.

  * `:account` — when set, asserts the URL's account segment matches
    this value. When `nil` (default), any account is accepted and
    the parsed value is reported in the recognised shape.

  ### Returns

  * `{:ok, recognised}` on a successful match.

  * `{:error, %Image.Plug.Error{tag: :malformed_url}}` when the path
    doesn't sit under the mount or has too few segments.

  ### Examples

      iex> conn = %Plug.Conn{
      ...>   path_info: ["demo", "image", "upload", "w_200,c_fill", "sample.jpg"],
      ...>   request_path: "/demo/image/upload/w_200,c_fill/sample.jpg",
      ...>   query_string: ""
      ...> }
      iex> {:ok, parsed} = Image.Plug.Provider.Cloudinary.URL.parse(conn, [])
      iex> parsed.options
      "w_200,c_fill"
      iex> parsed.delivery
      "upload"
      iex> parsed.source.ref
      "/sample.jpg"

  """
  @spec parse(Plug.Conn.t(), keyword()) :: {:ok, recognised()} | {:error, Error.t()}
  def parse(%Plug.Conn{path_info: path_info}, options) when is_list(options) do
    mount_segments = mount_segments(Keyword.get(options, :mount, ""))
    expected_account = Keyword.get(options, :account)
    decoded = Enum.map(path_info, &URI.decode/1)

    with {:ok, after_mount} <- strip_prefix(decoded, mount_segments),
         {:ok, parts} <- split_path(after_mount, expected_account) do
      with {:ok, source} <- build_source(parts.source_segments, parts.delivery) do
        {:ok,
         %{
           shape: :cloudinary,
           options: Enum.join(parts.transform_stages, ","),
           source: source,
           account: parts.account,
           resource_type: parts.resource_type,
           delivery: parts.delivery,
           signature: parts.signature
         }}
      end
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
      {:error, Error.new(:malformed_url, "request path does not sit under the configured mount")}
    end
  end

  defp split_path([account, resource_type, delivery | rest], expected_account)
       when rest != [] do
    cond do
      expected_account != nil and account != expected_account ->
        {:error,
         Error.new(:malformed_url, "cloudinary account segment does not match configured value",
           details: %{got: account, expected: expected_account}
         )}

      true ->
        {signature, after_signature} = pop_signature(rest)
        {transform_stages, source_segments} = split_transforms_and_source(after_signature)

        if source_segments == [] do
          {:error, Error.new(:malformed_url, "cloudinary URL has no source segment")}
        else
          {:ok,
           %{
             account: account,
             resource_type: resource_type,
             delivery: delivery,
             signature: signature,
             transform_stages: transform_stages,
             source_segments: source_segments
           }}
        end
    end
  end

  defp split_path(_, _) do
    {:error,
     Error.new(
       :malformed_url,
       "cloudinary URL needs at least <account>/<resource>/<delivery>/<source>"
     )}
  end

  defp pop_signature([first | rest] = segments) do
    if Regex.match?(@signature_segment_re, first) do
      {first, rest}
    else
      {nil, segments}
    end
  end

  # The last segment is always the source. Everything before it is a
  # transform stage IF it contains a Cloudinary transform marker (an
  # underscore between letters/digits, like `w_200`); otherwise we
  # treat it as part of the source path (folders).
  defp split_transforms_and_source(segments) do
    {transforms, sources} = Enum.split_while(segments, &looks_like_transform_stage?/1)

    case sources do
      [] ->
        # Edge case: every segment looked like a transform stage. Last
        # one is actually the source (cloudinary public-id with no
        # extension, rare).
        case transforms do
          [] -> {[], []}
          _ -> {Enum.drop(transforms, -1), [List.last(transforms)]}
        end

      _ ->
        {transforms, sources}
    end
  end

  defp looks_like_transform_stage?(segment) do
    # A transform stage is a comma-separated list of <prefix>_<value>
    # pairs. The simplest heuristic: contains a `_`, no `.` (extensions
    # only appear on the source), and every comma-split chunk has a
    # `_` in it.
    cond do
      String.contains?(segment, ".") ->
        false

      not String.contains?(segment, "_") ->
        false

      true ->
        segment
        |> String.split(",", trim: true)
        |> Enum.all?(fn chunk -> String.contains?(chunk, "_") end)
    end
  end

  defp build_source(segments, "fetch") do
    # `delivery=fetch` is a web-proxy: the source is an absolute
    # http(s) URL. Cloudinary accepts it either fully percent-encoded
    # (one path segment) or written in the natural form (split into
    # multiple segments by `/`). Path-split collapses `https://` to
    # `https:/`, so we restore the missing slash on rejoin.
    joined =
      segments
      |> Enum.join("/")
      |> case do
        "http:/" <> rest = original ->
          if String.starts_with?(rest, "/"), do: original, else: "http://" <> rest

        "https:/" <> rest = original ->
          if String.starts_with?(rest, "/"), do: original, else: "https://" <> rest

        other ->
          other
      end

    cond do
      String.starts_with?(joined, "http://") or String.starts_with?(joined, "https://") ->
        Source.url(joined)

      true ->
        Source.path("/" <> Enum.join(segments, "/"))
    end
  end

  defp build_source(segments, _delivery) do
    Source.path("/" <> Enum.join(segments, "/"))
  end
end
