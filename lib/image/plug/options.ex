defmodule Image.Plug.Options do
  @moduledoc """
  Validated, frozen configuration for `Image.Plug`.

  Built once at compile/boot time by `Image.Plug.init/1`. The
  request path then only reads struct fields.

  Construct with `new!/1`. Direct struct construction is discouraged —
  the validator enforces invariants such as "the provider module must
  export `parse/2`" that are not visible from the struct shape alone.
  """

  @type module_with_options :: {module(), keyword()}

  @typedoc """
  Signing configuration. `nil` disables signing entirely.

  When set, every request URL is verified against the configured
  `:keys` list (HMAC-SHA256). When `:required?` is `true`, an
  unsigned URL produces `:signature_required`. When `:required?` is
  `false`, unsigned URLs pass through but a signed URL with an
  invalid signature still 401s — defense in depth.
  """
  @type signing_options ::
          nil
          | %{
              required(:keys) => [String.t(), ...],
              optional(:required?) => boolean()
            }

  @type t :: %__MODULE__{
          provider: module(),
          provider_options: keyword(),
          source_resolver: module(),
          source_resolver_options: keyword(),
          variant_store: module(),
          variant_store_options: keyword(),
          on_error: Image.Plug.Pipeline.on_error(),
          max_pixels: pos_integer(),
          request_timeout: pos_integer(),
          telemetry_prefix: [atom(), ...],
          signing: signing_options()
        }

  @enforce_keys [:provider, :source_resolver]
  defstruct provider: nil,
            provider_options: [],
            source_resolver: nil,
            source_resolver_options: [],
            variant_store: Image.Plug.VariantStore.ETS,
            variant_store_options: [],
            on_error: :auto,
            max_pixels: 25_000_000,
            request_timeout: 10_000,
            telemetry_prefix: [:image_plug],
            signing: nil

  @doc """
  Validates a keyword list and returns an `Image.Plug.Options`
  struct.

  ### Arguments

  * `options` is a keyword list. The `:provider` and `:source_resolver`
    keys are required. Each must be a `{module, options}` tuple.

  ### Options

  * `:provider` (required) — `{module, options}` for an
    `Image.Plug.Provider` implementation.

  * `:source_resolver` (required) — `{module, options}` for an
    `Image.Plug.SourceResolver` implementation.

  * `:variant_store` — `{module, options}` for an
    `Image.Plug.VariantStore` implementation. Defaults to
    `{Image.Plug.VariantStore.ETS, []}`.

  * `:on_error` — error policy atom or `{:status, code}` tuple.
    Defaults to `:auto`.

  * `:max_pixels` — soft upper bound on the output pixel count.
    Defaults to `25_000_000`.

  * `:request_timeout` — total per-request budget in milliseconds.
    Defaults to `10_000`.

  * `:telemetry_prefix` — list of atoms prepended to telemetry event
    names. Defaults to `[:image_plug]`.

  ### Returns

  * An `Image.Plug.Options` struct.

  ### Examples

      iex> defmodule TestProv do
      ...>   @behaviour Image.Plug.Provider
      ...>   @impl true
      ...>   def parse(_conn, _options), do: {:error, Image.Plug.Error.new(:not_implemented, "test")}
      ...> end
      iex> defmodule TestRes do
      ...>   @behaviour Image.Plug.SourceResolver
      ...>   @impl true
      ...>   def load(_source, _options), do: {:error, Image.Plug.Error.new(:not_implemented, "test")}
      ...> end
      iex> options = Image.Plug.Options.new!(
      ...>   provider: {TestProv, []},
      ...>   source_resolver: {TestRes, []}
      ...> )
      iex> options.provider
      TestProv
      iex> options.on_error
      :auto

  """
  @spec new!(keyword()) :: t()
  def new!(options) when is_list(options) do
    {provider_mod, provider_opts} = take_module!(options, :provider)
    {resolver_mod, resolver_opts} = take_module!(options, :source_resolver)

    {store_mod, store_opts} =
      Keyword.get(options, :variant_store, {Image.Plug.VariantStore.ETS, []})
      |> normalise_module!(:variant_store)

    on_error = Keyword.get(options, :on_error, :auto)
    validate_on_error!(on_error)

    %__MODULE__{
      provider: provider_mod,
      provider_options: provider_opts,
      source_resolver: resolver_mod,
      source_resolver_options: resolver_opts,
      variant_store: store_mod,
      variant_store_options: store_opts,
      on_error: on_error,
      max_pixels: Keyword.get(options, :max_pixels, 25_000_000),
      request_timeout: Keyword.get(options, :request_timeout, 10_000),
      telemetry_prefix: Keyword.get(options, :telemetry_prefix, [:image_plug]),
      signing: validate_signing!(Keyword.get(options, :signing))
    }
  end

  defp validate_signing!(nil), do: nil

  defp validate_signing!(%{keys: [_ | _] = keys} = signing) when is_list(keys) do
    if Enum.all?(keys, &is_binary/1) do
      Map.put_new(signing, :required?, false)
    else
      raise ArgumentError,
            "Image.Plug: :signing :keys must all be binaries, got: #{inspect(keys)}"
    end
  end

  defp validate_signing!(other) do
    raise ArgumentError,
          "Image.Plug: :signing must be nil or %{keys: [\"...\"], required?: bool}, got: #{inspect(other)}"
  end

  defp take_module!(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> normalise_module!(value, key)
      :error -> raise ArgumentError, "Image.Plug: required option #{inspect(key)} is missing"
    end
  end

  defp normalise_module!({module, opts}, _key) when is_atom(module) and is_list(opts) do
    {module, opts}
  end

  defp normalise_module!(module, _key) when is_atom(module) do
    {module, []}
  end

  defp normalise_module!(other, key) do
    raise ArgumentError,
          "Image.Plug: option #{inspect(key)} must be a module or " <>
            "a {module, keyword} tuple, got: #{inspect(other)}"
  end

  defp validate_on_error!(value) do
    case value do
      v when v in [:auto, :render_error_image, :fallback_to_source, :status_text, :raise] ->
        :ok

      {:status, code} when is_integer(code) and code in 100..599 ->
        :ok

      other ->
        raise ArgumentError,
              "Image.Plug: :on_error must be :auto, :render_error_image, " <>
                ":fallback_to_source, :status_text, :raise, or {:status, code}, got: #{inspect(other)}"
    end
  end
end
