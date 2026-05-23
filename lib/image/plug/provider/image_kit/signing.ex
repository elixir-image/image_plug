defmodule Image.Plug.Provider.ImageKit.Signing do
  @moduledoc """
  ImageKit-flavoured HMAC URL signing.

  Per [ImageKit's docs](https://imagekit.io/docs/security#how-to-create-signed-urls):

  * HMAC-SHA1 over the canonical-string `<path-without-host><expiry-or-empty>`
    where `<path-without-host>` is the request path-and-query
    **excluding** the `ik-s` parameter and `<expiry-or-empty>` is
    the value of the `ik-t` parameter (or empty when absent).

  * Hex digest, lowercase.

  * Parameters: appended as `ik-s=<hex>` and optionally
    `ik-t=<unix-seconds>`.

  v0.1 ships HMAC-SHA1 (matching ImageKit's documented default).
  """

  alias Image.Plug.Error

  @signature_param "ik-s"
  @expiry_param "ik-t"

  @doc """
  Signs `path_with_query` (a request path, optionally with a query
  string) using the first key in `keys`. Returns the path with
  `?ik-s=<hex>` (or `&ik-s=<hex>` if a query is already present)
  appended.

  ### Options

  * `:expires_at` — `DateTime` or unix-seconds. Adds an
    `ik-t=<unix>` parameter; the verifier rejects after that time.
  """
  @spec sign(String.t(), [String.t(), ...], keyword()) :: String.t()
  def sign(path_with_query, [primary_key | _] = _keys, options \\ [])
      when is_binary(path_with_query) and is_binary(primary_key) do
    base =
      case encode_expiry(Keyword.get(options, :expires_at)) do
        nil -> path_with_query
        param -> append_query(path_with_query, param)
      end

    signature = hmac(primary_key, canonical_string(base))
    append_query(base, "#{@signature_param}=#{signature}")
  end

  @doc """
  Verifies the signature on `path_with_query`.

  Returns `:ok` or an `Image.Plug.Error` with one of
  `:signature_required`, `:invalid_signature`, `:signature_expired`.

  ### Options

  * `:required?` — when `true`, missing `?ik-s=` produces
    `:signature_required`. Default `false`.

  * `:now` — current unix-seconds for expiry comparison.
    Defaults to `System.system_time(:second)`. Test-only override.
  """
  @spec verify(String.t(), [String.t(), ...], keyword()) :: :ok | {:error, Error.t()}
  def verify(path_with_query, keys, options \\ [])
      when is_binary(path_with_query) and is_list(keys) do
    required? = Keyword.get(options, :required?, false)
    now = Keyword.get(options, :now, System.system_time(:second))

    case extract_signature(path_with_query) do
      {nil, _} when required? ->
        {:error, Error.new(:signature_required, "request must carry an `ik-s` query parameter")}

      {nil, _} ->
        :ok

      {provided, path_without_sig} ->
        with :ok <- check_expiry(path_without_sig, now),
             :ok <- check_signature(path_without_sig, provided, keys) do
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
        {:error, Error.new(:invalid_signature, "could not parse `ik-t` parameter")}
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
    canonical = canonical_string(path_without_sig)

    if Enum.any?(keys, fn key -> Plug.Crypto.secure_compare(provided, hmac(key, canonical)) end) do
      :ok
    else
      {:error, Error.new(:invalid_signature, "request signature does not match")}
    end
  end

  # ImageKit's canonical string is just the path-and-query (sans
  # `ik-s`). The expiry parameter, when present, is part of the
  # canonical-string by virtue of remaining in the query.
  defp canonical_string(path_with_query), do: path_with_query

  defp hmac(key, payload) when is_binary(key) and is_binary(payload) do
    :crypto.mac(:hmac, :sha, key, payload) |> Base.encode16(case: :lower)
  end
end
