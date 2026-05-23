defmodule Image.Plug.VariantStore.Persistence.File do
  @moduledoc """
  JSON-on-disk variant persistence backend.

  Serialises variants as a single JSON file containing a top-level
  array of variant objects:

      [
        {
          "name": "thumbnail",
          "options": "width=200,height=200,fit=cover,format=webp",
          "metadata": {"description": "card thumbnail"},
          "never_require_signed_urls": false,
          "inserted_at": "2026-04-26T12:34:56Z",
          "updated_at": "2026-04-26T12:34:56Z"
        },
        ...
      ]

  Whole-file rewrites on every `write/4` (atomic via
  write-temp-then-rename). Suitable for stores up to a few thousand
  variants; for larger or higher-write-rate workloads, plug a
  database-backed implementation in instead.

  ### Configuration

      variant_store: {Image.Plug.VariantStore.ETS, [
        persistence: {
          Image.Plug.VariantStore.Persistence.File,
          path: "/var/lib/image_plug/variants.json",
          provider: Image.Plug.Provider.Cloudflare  # default
        }
      ]}

  ### Options

  * `:path` (required) — absolute filesystem path. The directory
    must exist; the file is created if absent.

  * `:provider` — module used to re-parse persisted options
    strings at load time. Defaults to
    `Image.Plug.Provider.Cloudflare`.
  """

  @behaviour Image.Plug.VariantStore.Persistence

  alias Image.Plug.Variant

  require Logger

  @impl Image.Plug.VariantStore.Persistence
  def load(options) do
    path = Keyword.fetch!(options, :path)
    provider = Keyword.get(options, :provider, Image.Plug.Provider.Cloudflare)

    case File.read(path) do
      {:ok, "" <> _ = body} ->
        decode_and_parse(body, provider)

      {:error, :enoent} ->
        # First-boot: no persisted state yet.
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_failed, reason, path}}
    end
  end

  @impl Image.Plug.VariantStore.Persistence
  def write(_action, _name, _variant, options) do
    # Whole-file rewrite. Read every persistable variant from the
    # ETS table and re-serialise. Simpler than journalling and
    # bounded by the same total-variants limit (~100 per
    # Cloudflare's documented soft cap).
    path = Keyword.fetch!(options, :path)
    table = Keyword.get(options, :table, default_table())

    case dump(table) do
      {:ok, json} -> atomic_write(path, json)
      {:error, _} = error -> error
    end
  end

  defp default_table, do: Image.Plug.VariantStore.ETS.Server.default_table()

  defp dump(table) do
    variants =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_name, variant} -> variant end)
      |> Enum.filter(&persistable?/1)
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&to_json_map/1)

    {:ok, IO.iodata_to_binary(:json.encode(variants))}
  rescue
    e -> {:error, {:dump_failed, e}}
  end

  # The implicit "public" variant is always re-seeded by the ETS
  # server's init/1 — never persisted. Skip silently.
  defp persistable?(%Variant{name: "public"}), do: false

  defp persistable?(%Variant{options: nil} = variant) do
    Logger.warning(
      "image_plug: skipping variant #{inspect(variant.name)} during persistence — " <>
        "no :options string set. Programmatically-built pipelines need an :options " <>
        "string to round-trip through persistence."
    )

    false
  end

  defp persistable?(%Variant{options: options}) when is_binary(options) and options != "",
    do: true

  defp persistable?(_other), do: false

  defp to_json_map(%Variant{} = variant) do
    %{
      "name" => variant.name,
      "options" => variant.options,
      "metadata" => variant.metadata,
      "never_require_signed_urls" => variant.never_require_signed_urls?,
      "inserted_at" => datetime_to_iso(variant.inserted_at),
      "updated_at" => datetime_to_iso(variant.updated_at)
    }
  end

  defp datetime_to_iso(nil), do: nil
  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp atomic_write(path, body) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    case File.write(tmp, body) do
      :ok -> File.rename(tmp, path)
      error -> error
    end
  end

  defp decode_and_parse(body, provider) do
    case decode_safe(body) do
      {:ok, list} when is_list(list) ->
        {:ok, Enum.flat_map(list, &decode_variant(&1, provider))}

      {:ok, _other} ->
        {:error, :json_root_must_be_array}

      {:error, _} = error ->
        error
    end
  end

  defp decode_safe(body) do
    {:ok, :json.decode(body)}
  rescue
    e -> {:error, {:json_decode_failed, e}}
  end

  defp decode_variant(%{"name" => name, "options" => options} = entry, provider)
       when is_binary(name) and is_binary(options) do
    case parse_options(provider, options) do
      {:ok, pipeline} ->
        [
          %Variant{
            name: name,
            pipeline: pipeline,
            options: options,
            metadata: Map.get(entry, "metadata", %{}) |> ensure_map(),
            never_require_signed_urls?: !!Map.get(entry, "never_require_signed_urls", false),
            inserted_at: parse_iso(Map.get(entry, "inserted_at")),
            updated_at: parse_iso(Map.get(entry, "updated_at"))
          }
        ]

      {:error, reason} ->
        Logger.warning(
          "image_plug: skipping persisted variant #{inspect(name)} — could not " <>
            "re-parse :options string #{inspect(options)}: #{inspect(reason)}"
        )

        []
    end
  end

  defp decode_variant(other, _provider) do
    Logger.warning("image_plug: skipping malformed persisted variant entry: #{inspect(other)}")

    []
  end

  defp parse_options(Image.Plug.Provider.Cloudflare, options_string) do
    Image.Plug.Provider.Cloudflare.Options.parse(options_string)
  end

  defp parse_options(provider, _options_string) do
    {:error, {:no_parser_for_provider, provider}}
  end

  defp parse_iso(nil), do: nil

  defp parse_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_other), do: %{}
end
