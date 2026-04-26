defmodule Image.Plug.VariantStore.Persistence do
  @moduledoc """
  Behaviour for persisting variants across application restarts.

  A persistence backend is responsible for two things:

  * `c:load/1` — called once at boot when the variant store
    initialises. Returns the list of previously-stored variants.
    The store seeds them into its table before applying any
    application-env seeds.

  * `c:write/4` — called after every successful `put` or `delete`.
    Write-through, fire-and-forget: failures are logged at `:warn`
    but do not fail the originating CRUD operation.

  ### Built-in backends

  * `Image.Plug.VariantStore.Persistence.File` — JSON-on-disk.

  ### Configuration

  Configure on the ETS variant store:

      plug Image.Plug,
        ...
        variant_store: {Image.Plug.VariantStore.ETS, [
          persistence:
            {Image.Plug.VariantStore.Persistence.File,
             path: "/var/lib/image_plug/variants.json"}
        ]}

  ### Persistable variants

  Only variants whose `:options` field is set (i.e. variants
  created from a CDN-grammar options string) are persisted. Variants
  built programmatically from an `Image.Plug.Pipeline` struct (no
  options string) cannot be round-tripped without a pipeline codec
  and are skipped with a warning. If you build pipelines
  programmatically and want them persisted, also set the
  `:options` field with an equivalent options string.

  ### Provider

  Persisted variants store the original options string, not the
  parsed pipeline. At load time the string is re-parsed via the
  `:provider` option (defaulting to `Image.Plug.Provider.Cloudflare`).
  This dodges the JSON-serialisation problem for pipeline ops,
  which embed atoms and struct types that don't survive a
  round-trip cleanly.
  """

  alias Image.Plug.Variant

  @doc """
  Loads previously-persisted variants.

  ### Arguments

  * `options` is the keyword list configured on the persistence
    entry.

  ### Returns

  * `{:ok, [variant]}` on success. Empty list is fine — first run.

  * `{:error, reason}` to abort boot. Use sparingly; a fresh
    install with no persisted state is the normal first-boot
    condition and should return `{:ok, []}`, not an error.
  """
  @callback load(options :: keyword()) :: {:ok, [Variant.t()]} | {:error, term()}

  @doc """
  Writes a single variant change.

  Called after every successful `put` or `delete` on the variant
  store. Receives the action (`:put` or `:delete`), the variant
  name, and either the new variant struct (for `:put`) or `nil`
  (for `:delete`).

  ### Returns

  * `:ok` on success.

  * `{:error, reason}` on failure. The store logs the error at
    `:warn` but does not fail the originating CRUD call —
    persistence is fire-and-forget.
  """
  @callback write(
              action :: :put | :delete,
              name :: String.t(),
              variant :: Variant.t() | nil,
              options :: keyword()
            ) :: :ok | {:error, term()}
end
