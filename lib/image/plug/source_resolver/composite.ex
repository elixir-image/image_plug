defmodule Image.Plug.SourceResolver.Composite do
  @moduledoc """
  Source resolver that dispatches by `Image.Plug.Source.kind` to a
  configured set of per-kind resolvers.

  This is the resolver most hosts will use: a single `Image.Plug`
  configuration handles every URL form the Cloudflare provider can
  produce (file paths, absolute URLs, hosted asset ids).

  ### Configuration

  Each per-kind sub-resolver is configured as a keyword under its
  kind name. Sub-resolver options are passed through verbatim.

  * `:file` — keyword list passed to `Image.Plug.SourceResolver.File`.

  * `:http` — keyword list passed to `Image.Plug.SourceResolver.HTTP`.

  * `:hosted` — `{module, options}` for the host's hosted-asset
    resolver. There is no built-in implementation in v0.1; hosts
    plug their own asset store in here.

  Example:

      {Image.Plug.SourceResolver.Composite,
       file:   [root: "priv/static/uploads"],
       http:   [allowed_hosts: ["assets.example.com"]],
       hosted: {MyApp.AssetResolver, table: :my_assets}}
  """

  @behaviour Image.Plug.SourceResolver

  alias Image.Plug.{Error, Source}
  alias Image.Plug.SourceResolver

  @impl Image.Plug.SourceResolver
  def load(%Source{kind: kind} = source, options) do
    case dispatch(kind, options) do
      {:ok, {module, sub_options}} ->
        module.load(source, sub_options)

      {:error, _} = error ->
        error
    end
  end

  defp dispatch(:path, options) do
    case Keyword.fetch(options, :file) do
      {:ok, sub_options} -> {:ok, {SourceResolver.File, sub_options}}
      :error -> kind_not_configured(:path)
    end
  end

  defp dispatch(:url, options) do
    case Keyword.fetch(options, :http) do
      {:ok, sub_options} -> {:ok, {SourceResolver.HTTP, sub_options}}
      :error -> kind_not_configured(:url)
    end
  end

  defp dispatch(:hosted, options) do
    case Keyword.fetch(options, :hosted) do
      {:ok, {module, sub_options}} when is_atom(module) and is_list(sub_options) ->
        {:ok, {module, sub_options}}

      {:ok, module} when is_atom(module) ->
        {:ok, {module, []}}

      :error ->
        kind_not_configured(:hosted)
    end
  end

  defp kind_not_configured(kind) do
    {:error,
     Error.new(:invalid_option, "no resolver configured for source kind", details: %{kind: kind})}
  end
end
