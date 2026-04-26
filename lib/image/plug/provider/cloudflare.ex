defmodule Image.Plug.Provider.Cloudflare do
  @moduledoc """
  Cloudflare Images URL provider.

  Wires `Image.Plug.Provider.Cloudflare.URL` (URL-shape recognition)
  and `Image.Plug.Provider.Cloudflare.Options` (option parsing) into
  the `Image.Plug.Provider` behaviour.

  ### Options

  * `:mount` — string path prefix the plug is mounted under.
    Defaults to `""`. See `Image.Plug.Provider.Cloudflare.URL`.

  * `:hosted_account_hash` — when set, also recognises the
    hosted-image delivery form at
    `/<this-hash>/<image-id>/<variant-or-options>`.

  * `:strict?` — if `true` (default), unknown option keys produce an
    `:unknown_option` error. If `false`, unknown keys are logged and
    ignored.

  * `:variants_enabled?` — defaults to `true`. When `false`, a hosted
    URL whose tail looks like a variant name produces a
    `:variant_not_found` error instead of returning a `:variant`
    result.

  ### URL forms recognised

  * `/cdn-cgi/image/<options>/<absolute-path>`

  * `/cdn-cgi/image/<options>/<https-url>`

  * `/<account_hash>/<image-id>/<variant-or-options>` (when
    `:hosted_account_hash` is configured)
  """

  @behaviour Image.Plug.Provider

  alias Image.Plug.Error
  alias Image.Plug.Provider.Cloudflare.{Options, URL}

  @impl Image.Plug.Provider
  def parse(%Plug.Conn{} = conn, options) when is_list(options) do
    with {:ok, recognised} <- URL.parse(conn, Keyword.take(options, [:mount, :hosted_account_hash])) do
      build_result(recognised, options)
    end
  end

  defp build_result(%{variant: variant, source: source}, options)
       when is_binary(variant) do
    if Keyword.get(options, :variants_enabled?, true) do
      {:ok, {:variant, variant, [], source}}
    else
      {:error,
       Error.new(:variant_not_found, "variants are disabled on this provider",
         details: %{variant: variant}
       )}
    end
  end

  defp build_result(%{options: options_string, source: source}, options)
       when is_binary(options_string) do
    with {:ok, pipeline} <- Options.parse(options_string, Keyword.take(options, [:strict?])) do
      result =
        case pipeline.ops do
          [] -> {:passthrough, source}
          _ -> {:pipeline, pipeline, source}
        end

      {:ok, result}
    end
  end

  # No options string and no variant — only happens for the cdn-cgi
  # form when the source is missing, but URL.parse already rejects
  # that. Defensive `:malformed_url` here for completeness.
  defp build_result(_recognised, _options) do
    {:error, Error.new(:malformed_url, "URL produced neither options nor a variant")}
  end
end
