defmodule Image.Plug.Provider.Cloudinary.Signing do
  @moduledoc """
  Cloudinary-flavoured URL signing.

  Per [Cloudinary's docs](https://cloudinary.com/documentation/control_access_to_media#signed_delivery_urls):

  * SHA-256 (modern, default) over the canonical-string `<transforms>/<public-id><api-secret>`.
  * Signature appears as a path segment `s--<base64url-truncated>--`
    inserted between the delivery type (`upload`) and the first
    transform stage.
  * Cloudinary truncates the SHA-256 digest to 32 url-safe-base64
    characters by default. We follow that convention; longer
    signatures are rejected as invalid even if the prefix matches.

  v0.1 ships SHA-256 only. Cloudinary's older SHA-1 scheme (8-char
  signature, no `--` delimiters around the segment) is not
  supported — open an issue if you need it.

  Sign and verify share the same wire format. The module mirrors
  `Image.Plug.Signing`'s public API so it's a drop-in alternative
  when configuring the Cloudinary provider.
  """

  alias Image.Plug.Error

  @signature_re ~r/^s--([A-Za-z0-9_-]+)--$/
  @digest_length 32

  @doc """
  Signs a Cloudinary path with the first key in `keys`.

  ### Arguments

  * `path` is the path-and-query of a Cloudinary URL **without** an
    `s--<sig>--` segment. The signer inserts the segment between
    `<delivery>` (e.g. `upload`) and the first transform stage.

  * `keys` is a non-empty list of API secrets.

  ### Options

  * `:expires_at` — currently unused. Cloudinary's signed-URL flow
    relies on path-bound signatures rather than a per-URL expiry
    parameter; expirations live on the API-secret rotation cycle.

  ### Returns

  The signed path.
  """
  @spec sign(String.t(), [String.t(), ...], keyword()) :: String.t()
  def sign(path, [primary_key | _] = _keys, _options \\ [])
      when is_binary(path) and is_binary(primary_key) do
    {prefix, transforms_and_source} = split_at_delivery(path)
    signature = compute_signature(transforms_and_source, primary_key)
    "#{prefix}/s--#{signature}--/#{transforms_and_source}"
  end

  @doc """
  Verifies the signature on a Cloudinary path.

  Returns `:ok` or an `Image.Plug.Error` with one of
  `:signature_required`, `:invalid_signature`.

  ### Options

  * `:required?` — when `true`, missing `s--<sig>--` segment produces
    `:signature_required`. Default `false`.
  """
  @spec verify(String.t(), [String.t(), ...], keyword()) :: :ok | {:error, Error.t()}
  def verify(path, keys, options \\ [])
      when is_binary(path) and is_list(keys) do
    required? = Keyword.get(options, :required?, false)

    case extract_signature(path) do
      {nil, _} when required? ->
        {:error,
         Error.new(:signature_required,
           "request must carry a Cloudinary `s--<sig>--` segment"
         )}

      {nil, _} ->
        :ok

      {provided, transforms_and_source} ->
        check_signature(transforms_and_source, provided, keys)
    end
  end

  @doc """
  Splits a Cloudinary path into `{prefix, transforms_and_source}`
  where `prefix` is `/<account>/<resource-type>/<delivery>` and the
  remainder is the rest of the path with no leading `/`.

  Used by both signing and verification to canonicalise.
  """
  @spec split_at_delivery(String.t()) :: {String.t(), String.t()}
  def split_at_delivery(path) when is_binary(path) do
    segments = String.split(String.trim_leading(path, "/"), "/")

    case segments do
      [account, resource_type, delivery | rest] ->
        prefix = "/" <> account <> "/" <> resource_type <> "/" <> delivery
        {prefix, Enum.join(rest, "/")}

      _ ->
        {"", String.trim_leading(path, "/")}
    end
  end

  defp extract_signature(path) do
    {prefix, after_prefix} = split_at_delivery(path)

    case String.split(after_prefix, "/", parts: 2) do
      [first, rest] ->
        case Regex.run(@signature_re, first) do
          [_, sig] -> {sig, rest}
          _ -> {nil, prefix <> "/" <> after_prefix}
        end

      _ ->
        {nil, prefix <> "/" <> after_prefix}
    end
  end

  defp check_signature(transforms_and_source, provided, keys) do
    if Enum.any?(keys, fn key ->
         expected = compute_signature(transforms_and_source, key)
         Plug.Crypto.secure_compare(provided, expected)
       end) do
      :ok
    else
      {:error, Error.new(:invalid_signature, "request signature does not match")}
    end
  end

  # The canonical string is `<transforms>/<source><api-secret>`. The
  # SHA-256 digest is truncated to 32 url-safe-base64 characters
  # (Cloudinary's default; matches `signature_algorithm: 'sha256'`).
  defp compute_signature(transforms_and_source, key) do
    :crypto.hash(:sha256, transforms_and_source <> key)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, @digest_length)
  end
end
