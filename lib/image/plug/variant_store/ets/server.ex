defmodule Image.Plug.VariantStore.ETS.Server do
  @moduledoc false
  # GenServer that owns the ETS table backing
  # `Image.Plug.VariantStore.ETS`.
  #
  # The default table name is `:image_plug_variants`. The server
  # runs as a singleton under `Image.Plug.Application`. Hosts that
  # want isolated tables (e.g. tests) can start additional instances
  # under their own supervisor with `:name` and `:table` options.

  use GenServer

  alias Image.Plug.{Pipeline, Variant}

  @default_table :image_plug_variants

  @typedoc false
  @type option ::
          {:name, GenServer.name()}
          | {:table, atom()}
          | {:seed, [{String.t(), seed_value()}]}

  @typedoc false
  @type seed_value ::
          Pipeline.t()
          | Variant.t()
          | {provider :: module(), options_string :: String.t()}
          | {provider :: module(), options_string :: String.t(), variant_options :: keyword()}

  @doc false
  @spec default_table() :: atom()
  def default_table, do: @default_table

  @doc false
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc false
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @impl GenServer
  def init(options) do
    table = Keyword.get(options, :table, @default_table)
    persistence = normalise_persistence(Keyword.get(options, :persistence), table)

    :ets.new(table, [
      :set,
      :protected,
      :named_table,
      read_concurrency: true
    ])

    seed_public(table)
    hydrate_from_persistence(table, persistence)

    seeds = Keyword.get(options, :seed, [])
    Enum.each(seeds, fn {name, value} -> do_seed(table, name, value) end)

    {:ok, %{table: table, persistence: persistence}}
  end

  @impl GenServer
  def handle_call({:put, %Variant{} = variant}, _from, state) do
    now = DateTime.utc_now()

    stored =
      case :ets.lookup(state.table, variant.name) do
        [{_, %Variant{inserted_at: inserted_at}}] when not is_nil(inserted_at) ->
          %{variant | inserted_at: inserted_at, updated_at: now}

        _ ->
          %{variant | inserted_at: now, updated_at: now}
      end

    :ets.insert(state.table, {stored.name, stored})
    persist(state, :put, stored.name, stored)
    {:reply, {:ok, stored}, state}
  end

  def handle_call({:delete, name}, _from, state) do
    case :ets.take(state.table, name) do
      [_] ->
        persist(state, :delete, name, nil)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ---------- persistence helpers ----------

  defp normalise_persistence(nil, _table), do: nil

  defp normalise_persistence({module, opts}, table) when is_atom(module) and is_list(opts) do
    {module, Keyword.put_new(opts, :table, table)}
  end

  defp normalise_persistence(module, table) when is_atom(module) do
    {module, [table: table]}
  end

  defp hydrate_from_persistence(_table, nil), do: :ok

  defp hydrate_from_persistence(table, {module, opts}) do
    case module.load(opts) do
      {:ok, variants} when is_list(variants) ->
        Enum.each(variants, fn %Variant{name: name} = variant ->
          :ets.insert(table, {name, variant})
        end)

      {:error, reason} ->
        require Logger

        Logger.warning(
          "image_plug: variant persistence #{inspect(module)} failed to load: " <>
            "#{inspect(reason)}. Starting with no persisted variants."
        )
    end
  end

  defp persist(%{persistence: nil}, _action, _name, _variant), do: :ok

  defp persist(%{persistence: {module, opts}}, action, name, variant) do
    case module.write(action, name, variant, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "image_plug: variant persistence #{inspect(module)} write failed for " <>
            "#{action}=#{inspect(name)}: #{inspect(reason)}"
        )
    end
  end

  defp seed_public(table) do
    public = %Variant{
      name: "public",
      pipeline: Pipeline.new(provider: Image.Plug.Provider.Cloudflare),
      options: nil,
      metadata: %{},
      never_require_signed_urls?: true,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ets.insert(table, {public.name, public})
  end

  defp do_seed(table, name, %Pipeline{} = pipeline) do
    variant = %Variant{
      name: name,
      pipeline: pipeline,
      options: nil,
      metadata: %{},
      never_require_signed_urls?: false,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ets.insert(table, {name, variant})
  end

  defp do_seed(table, name, %Variant{} = variant) do
    :ets.insert(table, {name, %{variant | name: name}})
  end

  defp do_seed(table, name, {provider, options_string})
       when is_atom(provider) and is_binary(options_string) do
    do_seed(table, name, {provider, options_string, []})
  end

  defp do_seed(table, name, {provider, options_string, variant_options})
       when is_atom(provider) and is_binary(options_string) and is_list(variant_options) do
    case parse_options_string(provider, options_string) do
      {:ok, pipeline} ->
        variant = %Variant{
          name: name,
          pipeline: pipeline,
          options: options_string,
          metadata: Keyword.get(variant_options, :metadata, %{}),
          never_require_signed_urls?:
            Keyword.get(variant_options, :never_require_signed_urls?, false),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        :ets.insert(table, {name, variant})

      {:error, error} ->
        require Logger
        Logger.warning(
          "image_plug: failed to seed variant #{inspect(name)} from " <>
            "options string #{inspect(options_string)}: #{inspect(error)}"
        )
    end
  end

  defp parse_options_string(Image.Plug.Provider.Cloudflare, options_string) do
    Image.Plug.Provider.Cloudflare.Options.parse(options_string)
  end

  defp parse_options_string(_other_provider, _options_string) do
    {:error, :no_seed_parser_for_provider}
  end
end
