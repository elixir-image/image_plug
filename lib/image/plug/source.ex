defmodule Image.Plug.Source do
  @moduledoc """
  Reference to a source image. Produced by a provider, consumed by a
  source resolver.

  A source is intentionally a thin tagged reference. The provider names
  *what* the source is (an absolute path, an absolute URL, or a hosted
  asset id) and the source resolver decides *where the bytes come from*.

  Sources never hold image bytes themselves.
  """

  @typedoc """
  The kind of source. Determines which `Image.Plug.SourceResolver`
  implementation handles it.

  * `:path` — `ref` is an absolute path string. Resolved against a
    configured root directory by `Image.Plug.SourceResolver.File`.

  * `:url` — `ref` is an absolute `http(s)://` URL. Resolved by
    `Image.Plug.SourceResolver.HTTP` against an allow-list.

  * `:hosted` — `ref` is a `{account_hash, image_id}` tuple. Resolved
    by `Image.Plug.SourceResolver.Hosted` against a host-supplied
    asset table.
  """
  @type kind :: :path | :url | :hosted

  @type ref :: String.t() | {String.t(), String.t()}

  @type t :: %__MODULE__{
          kind: kind(),
          ref: ref(),
          headers: %{optional(String.t()) => String.t()}
        }

  @enforce_keys [:kind, :ref]
  defstruct [:kind, :ref, headers: %{}]

  @doc """
  Builds a `:path` source.

  ### Arguments

  * `path` is an absolute path string (must start with `/`).

  ### Returns

  * `{:ok, source}` on success.

  * `{:error, %Image.Plug.Error{tag: :invalid_option}}` if the path is
    not absolute or contains `..` segments.

  ### Examples

      iex> {:ok, source} = Image.Plug.Source.path("/foo/bar.jpg")
      iex> source.kind
      :path

      iex> {:error, error} = Image.Plug.Source.path("relative.jpg")
      iex> error.tag
      :invalid_option

  """
  @spec path(String.t()) :: {:ok, t()} | {:error, Image.Plug.Error.t()}
  def path(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error,
         Image.Plug.Error.new(:invalid_option, "source path must be absolute",
           details: %{path: path}
         )}

      ".." in Path.split(path) ->
        {:error,
         Image.Plug.Error.new(:invalid_option, "source path may not contain `..`",
           details: %{path: path}
         )}

      true ->
        {:ok, %__MODULE__{kind: :path, ref: path}}
    end
  end

  @doc """
  Builds a `:url` source.

  ### Arguments

  * `url` is an absolute `http://` or `https://` URL.

  ### Returns

  * `{:ok, source}` on success.

  * `{:error, %Image.Plug.Error{tag: :invalid_option}}` if the URL is
    missing a scheme or host.

  ### Examples

      iex> {:ok, source} = Image.Plug.Source.url("https://example.com/a.jpg")
      iex> source.kind
      :url

      iex> {:error, error} = Image.Plug.Source.url("not-a-url")
      iex> error.tag
      :invalid_option

  """
  @spec url(String.t()) :: {:ok, t()} | {:error, Image.Plug.Error.t()}
  def url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %__MODULE__{kind: :url, ref: url}}

      _ ->
        {:error,
         Image.Plug.Error.new(:invalid_option, "source url must be absolute http(s)",
           details: %{url: url}
         )}
    end
  end

  @doc """
  Builds a `:hosted` source.

  ### Arguments

  * `account_hash` is an opaque account identifier string.

  * `image_id` is an opaque image identifier string.

  ### Returns

  * An `Image.Plug.Source` struct (always succeeds).

  ### Examples

      iex> source = Image.Plug.Source.hosted("acct123", "img456")
      iex> source.kind
      :hosted
      iex> source.ref
      {"acct123", "img456"}

  """
  @spec hosted(String.t(), String.t()) :: t()
  def hosted(account_hash, image_id)
      when is_binary(account_hash) and is_binary(image_id) do
    %__MODULE__{kind: :hosted, ref: {account_hash, image_id}}
  end
end
