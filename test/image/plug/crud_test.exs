defmodule Image.Plug.CRUDTest do
  # Async: false so we don't race with other tests touching the
  # default singleton variant store.
  use ExUnit.Case, async: false

  alias Image.Plug.{Pipeline, Variant}
  alias Image.Plug.Pipeline.Ops

  setup do
    table = :"crud_test_#{System.unique_integer([:positive])}"
    name = :"#{table}_server"

    {:ok, pid} =
      Image.Plug.VariantStore.ETS.Server.start_link(name: name, table: table, seed: [])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{store_options: [table: table, server: name]}
  end

  test "put_variant/2 with an options string parses via the default provider", %{
    store_options: store_options
  } do
    assert {:ok, %Variant{name: "thumb", options: "width=100,fit=cover"}} =
             Image.Plug.put_variant("thumb", "width=100,fit=cover", store_options)

    assert {:ok, fetched} = Image.Plug.get_variant("thumb", store_options)
    assert [%Ops.Resize{width: 100, fit: :cover}] = fetched.pipeline.ops
  end

  test "put_variant/2 with a {provider, string} tuple", %{store_options: store_options} do
    assert {:ok, %Variant{name: "tup"}} =
             Image.Plug.put_variant(
               "tup",
               {Image.Plug.Provider.Cloudflare, "format=webp"},
               store_options
             )
  end

  test "put_variant/1 with a complete Variant struct", %{store_options: store_options} do
    variant = %Variant{name: "explicit", pipeline: Pipeline.new(), metadata: %{a: 1}}

    assert {:ok, stored} = Image.Plug.put_variant(variant, store_options)
    assert stored.metadata == %{a: 1}
  end

  test "get_variant/2 returns :not_found for unknown names", %{store_options: store_options} do
    assert {:error, :not_found} = Image.Plug.get_variant("nope", store_options)
  end

  test "delete_variant/2 removes the variant", %{store_options: store_options} do
    {:ok, _} = Image.Plug.put_variant("toremove", "width=50", store_options)
    assert :ok = Image.Plug.delete_variant("toremove", store_options)
    assert {:error, :not_found} = Image.Plug.get_variant("toremove", store_options)
  end

  test "list_variants/1 includes the seeded public + any inserts", %{store_options: store_options} do
    {:ok, _} = Image.Plug.put_variant("a", "width=10", store_options)

    {:ok, variants} = Image.Plug.list_variants(store_options)
    names = Enum.map(variants, & &1.name)

    assert "public" in names
    assert "a" in names
  end

  test "put_variant/2 with an invalid options string returns the parser error", %{
    store_options: store_options
  } do
    assert {:error, %Image.Plug.Error{tag: :unknown_option}} =
             Image.Plug.put_variant("bad", "wat=1", store_options)
  end
end
