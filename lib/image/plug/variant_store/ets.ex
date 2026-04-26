defmodule Image.Plug.VariantStore.ETS do
  @moduledoc """
  In-memory ETS-backed implementation of `Image.Plug.VariantStore`.

  A singleton owner process holds a `:protected` ETS table. Reads
  go straight to ETS; writes go through the owner process to
  serialise inserts and to populate the `:inserted_at` /
  `:updated_at` timestamps.

  ### Configuration

  Started by the `:image_plug` application with a default table
  name of `:image_plug_variants`. Variants are seeded from the
  application environment:

      # config/config.exs
      config :image_plug,
        variants: [
          {"thumbnail", "width=200,height=200,fit=cover,format=webp"},
          {"hero",      "width=1600,format=auto,quality=82"}
        ]

  Each entry value can be:

  * a Cloudflare-style options string (parsed by
    `Image.Plug.Provider.Cloudflare.Options`),

  * a `{provider, options_string, variant_options}` triple,

  * a pre-built `Image.Plug.Pipeline`, or

  * a complete `Image.Plug.Variant` struct.

  The implicit `"public"` variant is always seeded and represents
  Cloudflare's default "no transforms" behaviour. It can be overridden
  by adding an explicit `"public"` entry to the seeds.

  ### Per-call options

  Every callback accepts a `:table` keyword to address a non-default
  table — useful for tests and for hosts that run multiple isolated
  stores.
  """

  @behaviour Image.Plug.VariantStore

  alias Image.Plug.{Variant, VariantStore}

  @impl VariantStore
  def get(name, options \\ []) when is_binary(name) do
    table = Keyword.get(options, :table, default_table())

    case :ets.lookup(table, name) do
      [{^name, %Variant{} = variant}] -> {:ok, variant}
      [] -> {:error, :not_found}
    end
  end

  @impl VariantStore
  def put(%Variant{} = variant, options \\ []) do
    server = Keyword.get(options, :server, default_server())
    GenServer.call(server, {:put, variant})
  end

  @impl VariantStore
  def delete(name, options \\ []) when is_binary(name) do
    server = Keyword.get(options, :server, default_server())
    GenServer.call(server, {:delete, name})
  end

  @impl VariantStore
  def list(options \\ []) do
    table = Keyword.get(options, :table, default_table())

    variants =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_name, variant} -> variant end)
      |> Enum.sort_by(& &1.name)

    {:ok, variants}
  end

  @doc false
  def default_table, do: Image.Plug.VariantStore.ETS.Server.default_table()

  @doc false
  def default_server, do: Image.Plug.VariantStore.ETS.Server
end
