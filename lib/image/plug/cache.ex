defmodule Image.Plug.Cache do
  @moduledoc """
  HTTP-cache helpers used by `Image.Plug`.

  This module is pure. It computes a stable ETag from the source's
  `etag_seed` and the normalised pipeline's fingerprint, evaluates
  `If-None-Match` for conditional GETs, and produces a default
  `Cache-Control` directive.

  The ETag is a strong validator computed as:

      base64url(sha256(meta.etag_seed <> "|" <> pipeline_fingerprint <> "|" <> chosen_format))

  Because the pipeline is normalised first, two URLs that differ
  only in option order produce the same ETag — bandwidth-friendly
  and cache-friendly.
  """

  alias Image.Plug.Pipeline

  @typedoc """
  The shape returned by `compute/3`. The plug attaches these to the
  conn before the body is sent.
  """
  @type cache_info :: %{
          required(:etag) => String.t(),
          required(:cache_control) => String.t(),
          optional(:last_modified) => DateTime.t(),
          optional(:vary) => [String.t()]
        }

  @default_cache_control "public, max-age=3600, stale-while-revalidate=86400"

  @doc """
  Computes cache headers for a given source meta + normalised
  pipeline + chosen output format.

  ### Arguments

  * `meta` is the `Image.Plug.SourceResolver.meta` map.

  * `pipeline` is the (normalised) `Image.Plug.Pipeline`.

  * `chosen_format` is an atom describing the actual output format
    selected by the encoder (e.g. `:webp` even when the request was
    `format=auto`). Caller passes this so that two requests choosing
    different formats get different ETags.

  ### Returns

  * A `t:cache_info/0` map.

  """
  @spec compute(map(), Pipeline.t(), atom()) :: cache_info()
  def compute(meta, %Pipeline{} = pipeline, chosen_format) do
    etag = etag(meta, pipeline, chosen_format)
    base = %{etag: etag, cache_control: cache_control(meta), vary: vary(pipeline)}

    case Map.get(meta, :last_modified) do
      %DateTime{} = ts -> Map.put(base, :last_modified, ts)
      _ -> base
    end
  end

  @doc """
  Returns true when the request's `If-None-Match` header matches the
  computed ETag (i.e. we should respond 304).

  Accepts the bare ETag form and the `W/"..."` weak form, since some
  intermediaries strip the surrounding quotes.
  """
  @spec fresh?(Plug.Conn.t(), String.t()) :: boolean()
  def fresh?(%Plug.Conn{} = conn, etag) when is_binary(etag) do
    quoted = quoted_etag(etag)

    conn
    |> Plug.Conn.get_req_header("if-none-match")
    |> Enum.any?(fn header ->
      header
      |> String.split(",", trim: true)
      |> Enum.any?(fn entry ->
        normalised = entry |> String.trim() |> String.replace_prefix("W/", "")
        normalised == etag or normalised == quoted
      end)
    end)
  end

  @doc """
  Computes a stable fingerprint for a normalised pipeline. Used by
  `etag/3` and exposed for tests.
  """
  @spec fingerprint(Pipeline.t()) :: binary()
  def fingerprint(%Pipeline{ops: ops, output: output}) do
    payload = [
      Enum.map(ops, &op_fingerprint/1),
      "|",
      op_fingerprint(output)
    ]

    :crypto.hash(:sha256, IO.iodata_to_binary(payload))
  end

  defp op_fingerprint(%struct{} = op) do
    fields =
      op
      |> Map.from_struct()
      |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
      |> Enum.map(fn {k, v} -> [Atom.to_string(k), "=", inspect(v)] end)
      |> Enum.intersperse(";")

    [inspect(struct), "{", fields, "}"]
  end

  defp etag(meta, pipeline, chosen_format) do
    digest =
      :crypto.hash(:sha256, [
        meta.etag_seed,
        "|",
        fingerprint(pipeline),
        "|",
        Atom.to_string(chosen_format)
      ])

    Base.url_encode64(digest, padding: false)
  end

  defp quoted_etag(etag), do: ~s("#{etag}")

  defp cache_control(meta) do
    case Map.get(meta, :cache_control) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_cache_control
    end
  end

  defp vary(_pipeline), do: ["Accept"]
end
