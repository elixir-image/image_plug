defmodule Image.Plug.Signing do
  @moduledoc """
  HMAC signing and verification for `Image.Plug` request URLs.

  When configured, every request URL must carry a `?sig=<hex>` query
  parameter whose value is `HMAC-SHA256(secret, path)`, where `path`
  is the request path including any query string with the `sig`
  parameter removed. Optionally a `?exp=<unix-seconds>` parameter
  carries an expiry that the verifier checks against system time.

  ### Why query-parameter signing?

  A query parameter survives URL-rewriting intermediaries that may
  strip or reorder path segments, and it composes cleanly with the
  Cloudflare Images URL grammar (which uses `,` and `/` as
  significant path separators). Signed URLs work as drop-in
  replacements for unsigned ones — the canonical pipeline is
  unchanged.

  ### Why HMAC-SHA256?

  HMAC-SHA256 is the same primitive Cloudflare's signed-URL feature
  uses for its R2 and other URL-signing endpoints. Standard, fast,
  no key-distribution surprises. The verifier supports a list of
  keys for rotation: signing always uses the first key, verification
  accepts any.

  ### Example

      iex> keys = ["secret-1"]
      iex> path = "/cdn-cgi/image/width=200/photo.jpg"
      iex> signed = Image.Plug.Signing.sign(path, keys)
      iex> Image.Plug.Signing.verify(signed, keys, required?: true)
      :ok

  """

  alias Image.Plug.Error

  @type key :: String.t()
  @type keys :: [key(), ...]

  @signature_param "sig"
  @expiry_param "exp"

  @doc """
  Signs `path` with the first key in `keys`, returning the path with
  `?sig=<hex>` (and optionally `?exp=<unix-seconds>&sig=<hex>`)
  appended.

  ### Arguments

  * `path` is the request path string (with or without an existing
    query string). If a query string is present, the signature
    covers the full path including that query string.

  * `keys` is a non-empty list of secret-key strings. The first key
    is used for signing; the rest are accepted at verification time
    to support rotation.

  ### Options

  * `:expires_at` — `DateTime` or unix-seconds integer. When set,
    appends `?exp=<unix-seconds>` to the path and signs the result.
    Verification rejects the URL after this time.

  ### Returns

  * The path with the appropriate query parameters appended.

  ### Examples

      iex> Image.Plug.Signing.sign("/foo.jpg", ["secret"]) |> String.starts_with?("/foo.jpg?sig=")
      true

  """
  @spec sign(String.t(), keys(), keyword()) :: String.t()
  def sign(path, [primary_key | _] = _keys, options \\ []) when is_binary(path) and is_binary(primary_key) do
    expiry_param = encode_expiry(Keyword.get(options, :expires_at))

    base_with_expiry =
      case expiry_param do
        nil -> path
        param -> append_query(path, param)
      end

    signature = hmac(primary_key, base_with_expiry)
    append_query(base_with_expiry, "#{@signature_param}=#{signature}")
  end

  @doc """
  Verifies the signature on `path_with_query`.

  ### Arguments

  * `path_with_query` is the request path as it appeared on the
    wire, including any query string.

  * `keys` is a non-empty list of secret-key strings. Verification
    accepts a signature produced with any key in the list (for
    rotation).

  ### Options

  * `:required?` — when `true`, a missing `?sig` parameter causes a
    `:signature_required` error. When `false` (default), an
    unsigned URL passes verification — useful for gradual roll-out
    where some clients haven't been updated yet.

  * `:now` — current unix-seconds timestamp for expiry comparison.
    Defaults to `System.system_time(:second)`. Test-only override.

  ### Returns

  * `:ok` when the signature is valid (or absent and not required).

  * `{:error, %Image.Plug.Error{tag: :signature_required}}` when no
    `?sig` is present and signing is required.

  * `{:error, %Image.Plug.Error{tag: :invalid_signature}}` when the
    `?sig` value does not match any key.

  * `{:error, %Image.Plug.Error{tag: :signature_expired}}` when an
    `?exp` parameter is present and has passed.

  """
  @spec verify(String.t(), keys(), keyword()) :: :ok | {:error, Error.t()}
  def verify(path_with_query, keys, options \\ []) when is_binary(path_with_query) and is_list(keys) do
    required? = Keyword.get(options, :required?, false)
    now = Keyword.get(options, :now, System.system_time(:second))

    case extract_signature(path_with_query) do
      {nil, _path_without_sig} when required? ->
        {:error, Error.new(:signature_required, "request must carry a ?sig query parameter")}

      {nil, _path_without_sig} ->
        :ok

      {provided_signature, path_without_sig} ->
        with :ok <- check_expiry(path_without_sig, now),
             :ok <- check_signature(path_without_sig, provided_signature, keys) do
          :ok
        end
    end
  end

  defp encode_expiry(nil), do: nil
  defp encode_expiry(value) when is_integer(value), do: "#{@expiry_param}=#{value}"

  defp encode_expiry(%DateTime{} = dt) do
    "#{@expiry_param}=#{DateTime.to_unix(dt)}"
  end

  defp append_query(path, param) do
    case String.contains?(path, "?") do
      true -> "#{path}&#{param}"
      false -> "#{path}?#{param}"
    end
  end

  # Returns `{signature_or_nil, path_with_sig_removed}`.
  defp extract_signature(path_with_query) do
    case String.split(path_with_query, "?", parts: 2) do
      [path] ->
        {nil, path}

      [path, query] ->
        {sig, kept_params} =
          query
          |> String.split("&")
          |> Enum.reduce({nil, []}, fn entry, {sig_acc, kept_acc} ->
            case String.split(entry, "=", parts: 2) do
              [@signature_param, value] -> {value, kept_acc}
              _ -> {sig_acc, kept_acc ++ [entry]}
            end
          end)

        {sig, rebuild(path, kept_params)}
    end
  end

  defp rebuild(path, []), do: path
  defp rebuild(path, params), do: "#{path}?#{Enum.join(params, "&")}"

  defp check_expiry(path_without_sig, now) do
    case extract_expiry(path_without_sig) do
      nil ->
        :ok

      expiry when is_integer(expiry) and expiry >= now ->
        :ok

      expiry when is_integer(expiry) ->
        {:error,
         Error.new(:signature_expired, "signed URL has expired",
           details: %{expired_at: expiry, now: now}
         )}

      _ ->
        {:error, Error.new(:invalid_signature, "could not parse `?exp` parameter")}
    end
  end

  defp extract_expiry(path_with_query) do
    case String.split(path_with_query, "?", parts: 2) do
      [_path] ->
        nil

      [_path, query] ->
        query
        |> String.split("&")
        |> Enum.find_value(fn entry ->
          case String.split(entry, "=", parts: 2) do
            [@expiry_param, value] -> parse_integer(value)
            _ -> nil
          end
        end)
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp check_signature(path_without_sig, provided, keys) do
    if Enum.any?(keys, fn key -> Plug.Crypto.secure_compare(provided, hmac(key, path_without_sig)) end) do
      :ok
    else
      {:error, Error.new(:invalid_signature, "request signature does not match")}
    end
  end

  defp hmac(key, payload) when is_binary(key) and is_binary(payload) do
    :crypto.mac(:hmac, :sha256, key, payload) |> Base.encode16(case: :lower)
  end
end
