defmodule Image.Plug.Provider.Cloudflare.URL do
  @moduledoc """
  URL-shape recognition for the Cloudflare Images URL grammar.

  Two forms are recognised:

  ### Remote-image transform

      /cdn-cgi/image/<options>/<source>

  Where `<source>` is either an absolute path (`/foo/bar.jpg`) or an
  absolute URL (`http://...` or `https://...`). Always recognised.

  ### Hosted-image delivery

      /<account_hash>/<image-id>/<variant-or-options>

  Recognised when the provider is configured with
  `:hosted_account_hash`. The trailing segment is treated as a
  variant name iff it contains no `=` character (matching
  Cloudflare's documented rule); otherwise it is parsed as an
  options string. An empty trailing segment maps to the implicit
  `"public"` variant.

  This module does not interpret the options string — that is
  `Image.Plug.Provider.Cloudflare.Options`' job — and it does not
  load any source bytes.
  """

  alias Image.Plug.{Error, Source}

  @cdn_cgi_marker "cdn-cgi"
  @cdn_cgi_kind "image"
  @default_variant "public"

  @typedoc """
  The recognised URL shape, ready for the options parser and the
  source resolver.

  * `:shape` — `:remote` (cdn-cgi form) or `:hosted` (delivery form).

  * `:options` — an options string. `nil` for the hosted form when
    the trailing segment was a variant name.

  * `:variant` — a variant name. `nil` for the remote form and for
    the hosted form when the trailing segment looked like options.

  * `:source` — the `Image.Plug.Source` derived from the URL.
  """
  @type recognised :: %{
          shape: :remote | :hosted,
          options: String.t() | nil,
          variant: String.t() | nil,
          source: Source.t()
        }

  @doc """
  Parses the request path of a `Plug.Conn` into a recognised URL
  shape.

  ### Arguments

  * `conn` is a `Plug.Conn` struct.

  * `options` is a keyword list. The following keys are honoured:

  ### Options

  * `:mount` — string path prefix that the plug is mounted under.
    Stripped before pattern matching. Defaults to `""`.

  * `:hosted_account_hash` — when set, also recognise
    `/<this-hash>/<image-id>/<tail>`. Defaults to `nil`.

  ### Returns

  * `{:ok, recognised}` on a successful match.

  * `{:error, %Image.Plug.Error{tag: :malformed_url}}` when the
    path does not match either form.

  * `{:error, %Image.Plug.Error{tag: :invalid_option}}` when the
    source segment is malformed.

  ### Examples

      iex> conn = %Plug.Conn{
      ...>   path_info: ["cdn-cgi", "image", "width=200", "foo", "bar.jpg"],
      ...>   request_path: "/cdn-cgi/image/width=200/foo/bar.jpg"
      ...> }
      iex> {:ok, %{shape: :remote, options: "width=200", source: source}} =
      ...>   Image.Plug.Provider.Cloudflare.URL.parse(conn, [])
      iex> source.kind
      :path

      iex> conn = %Plug.Conn{
      ...>   path_info: ["acct123", "img456", "thumbnail"],
      ...>   request_path: "/acct123/img456/thumbnail"
      ...> }
      iex> {:ok, parsed} =
      ...>   Image.Plug.Provider.Cloudflare.URL.parse(conn,
      ...>     hosted_account_hash: "acct123"
      ...>   )
      iex> {parsed.shape, parsed.variant, parsed.source.ref}
      {:hosted, "thumbnail", {"acct123", "img456"}}

  """
  @spec parse(Plug.Conn.t(), keyword()) ::
          {:ok, recognised()} | {:error, Error.t()}
  def parse(%Plug.Conn{path_info: path_info}, options) when is_list(options) do
    mount_segments = mount_segments(Keyword.get(options, :mount, ""))
    hosted_hash = Keyword.get(options, :hosted_account_hash)

    decoded = Enum.map(path_info, &URI.decode/1)

    case strip_prefix(decoded, mount_segments) do
      {:ok, segments} ->
        dispatch(segments, hosted_hash)

      :error ->
        {:error, Error.new(:malformed_url, "request path does not match the configured mount")}
    end
  end

  defp dispatch([@cdn_cgi_marker, @cdn_cgi_kind, options_segment | source_segments], _hosted_hash)
       when source_segments != [] do
    with {:ok, source} <- build_remote_source(source_segments) do
      {:ok, %{shape: :remote, options: options_segment, variant: nil, source: source}}
    end
  end

  defp dispatch([hash, image_id | tail], hash)
       when is_binary(hash) and is_binary(image_id) and hash != "" do
    parse_hosted_tail(hash, image_id, tail)
  end

  defp dispatch([hash, image_id], hash)
       when is_binary(hash) and is_binary(image_id) and hash != "" do
    parse_hosted_tail(hash, image_id, [])
  end

  defp dispatch(_segments, _hosted_hash) do
    {:error, Error.new(:malformed_url, "URL does not match any Cloudflare form")}
  end

  defp parse_hosted_tail(hash, image_id, segments) do
    source = Source.hosted(hash, image_id)
    tail = segments |> Enum.join("/")

    cond do
      tail == "" ->
        {:ok, %{shape: :hosted, options: nil, variant: @default_variant, source: source}}

      String.contains?(tail, "=") ->
        {:ok, %{shape: :hosted, options: tail, variant: nil, source: source}}

      true ->
        {:ok, %{shape: :hosted, options: nil, variant: tail, source: source}}
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

  defp build_remote_source([first | _rest] = segments) do
    cond do
      # Path-info still has the scheme split as its own segment
      # (e.g. unit-test conns built without percent-encoding).
      first == "http:" or first == "https:" ->
        url = rebuild_url(segments)
        Source.url(url)

      # Percent-encoded URL collapsed by `URI.decode/1` into a
      # single segment that already contains the scheme. This is
      # the production form because clients percent-encode the
      # inner URL to keep the path-split clean.
      String.starts_with?(first, "http://") or String.starts_with?(first, "https://") ->
        Source.url(Enum.join(segments, "/"))

      true ->
        path = "/" <> Enum.join(segments, "/")
        Source.path(path)
    end
  end

  # `path_info` may either preserve the empty segment between `//`
  # (`["https:", "", "example.com", "a.jpg"]`) or trim it
  # (`["https:", "example.com", "a.jpg"]`). Handle both shapes.
  defp rebuild_url([scheme, "" | rest]) when scheme in ["http:", "https:"] do
    scheme <> "//" <> Enum.join(rest, "/")
  end

  defp rebuild_url([scheme | rest]) when scheme in ["http:", "https:"] do
    scheme <> "//" <> Enum.join(rest, "/")
  end

  defp rebuild_url(segments) do
    Enum.join(segments, "/")
  end
end
