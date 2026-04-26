defmodule Image.Plug.Variant do
  @moduledoc """
  A named, stored pipeline that requests can resolve by name.

  Variants are the project's analogue of Cloudflare Images variants:
  reusable templates that any URL can name. The `:options` field holds
  the original provider-specific options string for round-tripping
  through the admin API; `:pipeline` holds the parsed canonical form.
  """

  alias Image.Plug.Pipeline

  @type t :: %__MODULE__{
          name: String.t(),
          pipeline: Pipeline.t(),
          options: nil | String.t(),
          metadata: map(),
          never_require_signed_urls?: boolean(),
          inserted_at: nil | DateTime.t(),
          updated_at: nil | DateTime.t()
        }

  @enforce_keys [:name, :pipeline]
  defstruct name: nil,
            pipeline: nil,
            options: nil,
            metadata: %{},
            never_require_signed_urls?: false,
            inserted_at: nil,
            updated_at: nil
end
