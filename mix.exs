defmodule Image.Plug.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/elixir-image/image_plug"

  def project do
    [
      app: :image_plug,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      description: description(),
      source_url: @source_url,
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:mix, :plug, :ex_unit],
        flags: [:error_handling, :unknown, :extra_return],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Image.Plug.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:image, "~> 0.72"},
      {:vix, "~> 0.38"},
      {:telemetry, "~> 1.2"},
      {:req, "~> 0.5", optional: true},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:bypass, "~> 2.1", only: [:test]},
      {:stream_data, "~> 1.1", only: [:test]},
      {:ex_doc, "~> 0.34", only: [:dev, :release], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ] ++ maybe_json_polyfill()
  end

  defp maybe_json_polyfill do
    if Code.ensure_loaded?(:json) do
      []
    else
      [{:json_polyfill, "~> 0.2 or ~> 1.0"}]
    end
  end

  defp description do
    "A pluggable Plug-based image server. Maps URLs to a canonical image " <>
      "processing pipeline executed via the Image library, with named, " <>
      "stored variants. Ships a Cloudflare Images URL provider."
  end

  defp package do
    [
      maintainers: ["Kip Cole"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md",
        "logo.jpg",
        "guides"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "logo.jpg",
      extras: [
        "README.md",
        "guides/usage.md",
        "guides/sources.md",
        "guides/face_aware.md",
        "guides/cdn_origin.md",
        "guides/cloudflare_conformance.md",
        "guides/imgix_conformance.md",
        "guides/cloudinary_conformance.md",
        "guides/image_kit_conformance.md",
        "guides/iiif_conformance.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r{guides/},
        About: ["README.md", "CHANGELOG.md"]
      ],
      source_ref: "v#{@version}",
      formatters: ["html", "markdown"],
      groups_for_modules: [
        "Public API": [
          Image.Plug,
          Image.Plug.Admin,
          Image.Plug.Pipeline,
          Image.Plug.Provider,
          Image.Plug.Source,
          Image.Plug.SourceResolver,
          Image.Plug.Variant,
          Image.Plug.VariantStore,
          Image.Plug.Capabilities,
          Image.Plug.Error
        ],
        "Pipeline operations": ~r/^Image\.Plug\.Pipeline\.Ops/,
        "Cloudflare provider": ~r/^Image\.Plug\.Provider\.Cloudflare/,
        "Default source resolvers": ~r/^Image\.Plug\.SourceResolver\.[A-Z]/,
        "Default variant stores": ~r/^Image\.Plug\.VariantStore\.[A-Z]/,
        Internals: ~r/^Image\.Plug\./
      ]
    ]
  end
end
