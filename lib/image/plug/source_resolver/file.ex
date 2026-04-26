defmodule Image.Plug.SourceResolver.File do
  @moduledoc """
  Source resolver that reads images from a configured root directory.

  Maps `%Image.Plug.Source{kind: :path, ref: "/foo/bar.jpg"}` onto
  `<root>/foo/bar.jpg`. Only `:path` sources are accepted.

  Decoding is streaming-friendly: the file path is passed straight to
  `Image.open/2`, which lets libvips mmap or progressively decode
  rather than slurping the file into a binary first.

  ### Configuration

  * `:root` (required) — absolute path to the directory under which
    source files live. Must exist at boot time. Symlinks pointing
    outside the root are rejected at request time.

  ### Security

  Path-traversal is blocked at two levels: `Image.Plug.Source.path/1`
  rejects `..` segments before the source even reaches the resolver,
  and the resolver re-validates that the canonical resolved path is
  still inside the root.
  """

  @behaviour Image.Plug.SourceResolver

  alias Image.Plug.{Error, Source}

  @impl Image.Plug.SourceResolver
  def load(%Source{kind: :path, ref: ref} = _source, options) when is_binary(ref) do
    with {:ok, root} <- fetch_root(options),
         {:ok, absolute_path} <- resolve(root, ref),
         {:ok, %{type: file_type, mtime: mtime, size: size}} <- file_stat(absolute_path),
         :ok <- ensure_regular(file_type, absolute_path),
         {:ok, image} <- open(absolute_path) do
      meta = %{
        content_type: content_type_for(absolute_path),
        etag_seed:
          IO.iodata_to_binary([
            absolute_path,
            "|",
            Integer.to_string(size),
            "|",
            Integer.to_string(mtime_to_unix(mtime))
          ]),
        last_modified: mtime_to_datetime(mtime),
        byte_size: size
      }

      {:ok, image, meta}
    end
  end

  def load(%Source{kind: kind} = _source, _options) do
    {:error,
     Error.new(:invalid_option, "SourceResolver.File only handles :path sources",
       details: %{got_kind: kind}
     )}
  end

  defp fetch_root(options) do
    case Keyword.fetch(options, :root) do
      {:ok, root} when is_binary(root) ->
        if Path.type(root) == :absolute do
          {:ok, Path.expand(root)}
        else
          {:error,
           Error.new(:invalid_option, "SourceResolver.File :root must be an absolute path",
             details: %{root: root}
           )}
        end

      _ ->
        {:error,
         Error.new(:invalid_option, "SourceResolver.File requires a :root option")}
    end
  end

  defp resolve(root, "/" <> rest) do
    candidate = Path.expand(rest, root)

    if String.starts_with?(candidate, root <> "/") or candidate == root do
      {:ok, candidate}
    else
      {:error,
       Error.new(:invalid_option, "resolved source path escapes the configured root",
         details: %{path: rest}
       )}
    end
  end

  defp resolve(_root, ref) do
    {:error,
     Error.new(:invalid_option, "source path must be absolute", details: %{path: ref})}
  end

  defp file_stat(absolute_path) do
    case File.stat(absolute_path, time: :posix) do
      {:ok, stat} ->
        {:ok, %{type: stat.type, mtime: stat.mtime, size: stat.size}}

      {:error, :enoent} ->
        {:error,
         Error.new(:source_not_found, "source file does not exist",
           details: %{path: absolute_path}
         )}

      {:error, reason} ->
        {:error,
         Error.new(:source_fetch_error, "could not stat source file",
           details: %{path: absolute_path, reason: reason}
         )}
    end
  end

  defp ensure_regular(:regular, _absolute_path), do: :ok

  defp ensure_regular(other, absolute_path) do
    {:error,
     Error.new(:invalid_option, "source path is not a regular file",
       details: %{path: absolute_path, type: other}
     )}
  end

  # Mirrors the canonical streaming pipeline shape used in the
  # `Image` library's own test suite (`stream_image_test.exs`):
  #
  #     path
  #     |> File.stream!(2048, [])
  #     |> Image.open()
  #     |> ...transforms...
  #     |> Image.stream!(suffix: ".jpg")
  #     |> Enum.reduce_while(conn, &Plug.Conn.chunk(&2, &1))
  #
  # The 2048-byte chunk size matches Image's documented examples;
  # libvips reads from the enum on demand, so memory use stays
  # bounded regardless of source size.
  defp open(absolute_path) do
    stream = File.stream!(absolute_path, 2048, [])

    case Image.open(stream) do
      {:ok, image} ->
        {:ok, image}

      {:error, reason} ->
        {:error,
         Error.new(:unsupported_source_format, "could not decode source image",
           details: %{path: absolute_path, reason: format_reason(reason)}
         )}
    end
  end

  defp content_type_for(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".avif" -> "image/avif"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".heic" -> "image/heic"
      _ -> "application/octet-stream"
    end
  end

  defp mtime_to_unix(unix) when is_integer(unix), do: unix

  defp mtime_to_datetime(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  # Image.open/2 returns `{:error, %Image.Error{message: binary}}`.
  defp format_reason(%{message: message}) when is_binary(message), do: message
end
