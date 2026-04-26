defmodule Image.Plug.VariantStore do
  @moduledoc """
  Behaviour for variant stores.

  A variant store persists `Image.Plug.Variant` records keyed by
  name. Reads are expected to be cheap (every request that resolves a
  variant performs one read); writes are expected to be infrequent.

  The default implementation `Image.Plug.VariantStore.ETS` is
  in-memory. A file-backed and a database-backed store may follow in
  later milestones.
  """

  alias Image.Plug.Variant

  @doc """
  Fetches a variant by name.

  Returns `{:ok, variant}` or `{:error, :not_found}`.
  """
  @callback get(name :: String.t(), options :: keyword()) ::
              {:ok, Variant.t()} | {:error, :not_found}

  @doc """
  Inserts or updates a variant.

  Returns `{:ok, stored}` where `stored` may differ from the input
  (for example, with `:inserted_at` / `:updated_at` populated).
  """
  @callback put(Variant.t(), options :: keyword()) ::
              {:ok, Variant.t()} | {:error, term()}

  @doc """
  Deletes a variant by name.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @callback delete(name :: String.t(), options :: keyword()) ::
              :ok | {:error, :not_found}

  @doc """
  Lists every stored variant. The order is implementation-defined.
  """
  @callback list(options :: keyword()) :: {:ok, [Variant.t()]}
end
