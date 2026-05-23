defmodule Image.Plug.SourceResolver.CompositeTest do
  use ExUnit.Case, async: true

  alias Image.Plug.{Error, Source}
  alias Image.Plug.SourceResolver.Composite

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  defmodule StubHosted do
    @behaviour Image.Plug.SourceResolver

    @impl true
    def load(%Source{kind: :hosted, ref: ref}, options) do
      send(self(), {:hosted_called, ref, options})

      {:error,
       Image.Plug.Error.new(:source_not_found, "stub", details: %{ref: ref, options: options})}
    end
  end

  test "dispatches :path sources to SourceResolver.File" do
    {:ok, source} = Source.path("/sample.jpg")

    assert {:ok, _image, %{content_type: "image/jpeg"}} =
             Composite.load(source, file: [root: @fixtures])
  end

  test "dispatches :hosted sources to the configured module" do
    source = Source.hosted("acct", "img")

    assert {:error, %Error{tag: :source_not_found, details: details}} =
             Composite.load(source, hosted: {StubHosted, table: :foo})

    assert details.options == [table: :foo]
    assert_received {:hosted_called, {"acct", "img"}, [table: :foo]}
  end

  test "rejects :url with no :http config" do
    {:ok, source} = Source.url("https://example.com/a.jpg")

    assert {:error, %Error{tag: :invalid_option, details: %{kind: :url}}} =
             Composite.load(source, file: [root: @fixtures])
  end

  test "rejects :hosted with no :hosted config" do
    source = Source.hosted("acct", "img")

    assert {:error, %Error{tag: :invalid_option, details: %{kind: :hosted}}} =
             Composite.load(source, file: [root: @fixtures])
  end
end
