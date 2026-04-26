defmodule Image.Plug.Provider.Imgix.Signing do
  @moduledoc """
  Imgix-flavoured HMAC URL signing.

  Per [imgix's docs](https://docs.imgix.com/en/latest/setup/securing-images):

  * HMAC-SHA256 (we ship SHA-256 only; SHA-1 is not supported).
  * Payload: `secret <> path <> "?" <> query` where the query
    excludes the `s` parameter. When the query is empty the
    payload is `secret <> path` with no trailing `?`.
  * Hex digest, lowercase.
  * Parameter: appended as `s=<hex>`.

  Differences from `Image.Plug.Signing` (Cloudflare-flavoured):

  * Parameter name: `s` vs Cloudflare's `sig`. Imgix's choice
    matches what the imgix CDN itself uses; matters for wire-
    format compatibility with imgix's own URLs.

  * Canonical-string rule: imgix prepends the secret to the
    payload; Cloudflare uses the secret as the HMAC key only.

  Sign and verify share the same wire format, so a URL signed by
  `sign/3` verifies under `verify/3` with the same key. The
  module mirrors `Image.Plug.Signing`'s public API so it's a
  drop-in alternative when configuring the imgix provider.
  """

  alias Image.Plug.Error

  @signature_param "s"
  @expiry_param "expires"

  @doc """
  Signs `path_with_query` (a request path, optionally with a query
  string) using the first key in `keys`. Returns the path with
  `?s=<hex>` (or `&s=<hex>` if a query is already present)
  appended.

  ### Options

  * `:expires_at` — `DateTime` or unix-seconds. Adds an
    `expires=<unix>` parameter; the verifier rejects after that
    time.
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
  `:signature_required`, `:invalid_signature`,
  `:signature_expired`.

  ### Options

  * `:required?` — when `true`, missing `?s=` produces
    `:signature_required`. Default `false` (defense-in-depth: a
    bad signature is always rejected, but a missing signature
    only fails when the deployment requires it).

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
        {:error, Error.new(:signature_required, "request must carry an `s` query parameter")}

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

  # Extract the `s` parameter and rebuild the path-with-query
  # *without* it. The verifier signs over the rebuild result.
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
        {:error, Error.new(:invalid_signature, "could not parse `expires` parameter")}
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

  # Imgix's canonical string is the secret prepended to the
  # path-and-query. The HMAC payload IS the canonical string;
  # the secret is also used as the HMAC key (for resistance to
  # length-extension attacks).
  defp canonical_string(path_with_query), do: path_with_query

  defp hmac(key, payload) when is_binary(key) and is_binary(payload) do
    # Imgix prepends the secret to the payload, then uses HMAC-SHA256
    # with the secret as the key.
    :crypto.mac(:hmac, :sha256, key, key <> payload) |> Base.encode16(case: :lower)
  end
end
