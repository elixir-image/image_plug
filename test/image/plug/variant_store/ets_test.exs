defmodule Image.Plug.VariantStore.ETSTest do
  use ExUnit.Case, async: false

  alias Image.Plug.{Pipeline, Variant}
  alias Image.Plug.VariantStore.ETS

  setup do
    # Each test gets a fresh table + GenServer to keep state isolated
    # without colliding with the application-level singleton.
    # `start_supervised!/1` registers the process under ExUnit's
    # test supervisor — teardown is automatic and race-free
    # (vs. the `on_exit + GenServer.stop` pattern, which can
    # crash with `:noproc` when the linked GenServer dies with
    # the test process before `on_exit/1` runs).
    table = :"variants_test_#{System.unique_integer([:positive])}"
    name = :"#{table}_server"

    start_supervised!(
      {Image.Plug.VariantStore.ETS.Server, name: name, table: table, seed: []}
    )

    %{table: table, server: name}
  end

  test "the public variant is always seeded", %{table: table} do
    assert {:ok, %Variant{name: "public"}} = ETS.get("public", table: table)
  end

  test "put/2 stores a variant and assigns timestamps", %{table: table, server: server} do
    variant = %Variant{name: "thumb", pipeline: Pipeline.new()}

    assert {:ok, stored} = ETS.put(variant, server: server)
    assert %Variant{name: "thumb", inserted_at: %DateTime{}, updated_at: %DateTime{}} = stored
    assert {:ok, ^stored} = ETS.get("thumb", table: table)
  end

  test "put/2 of an existing variant preserves :inserted_at", %{table: table, server: server} do
    variant = %Variant{name: "card", pipeline: Pipeline.new()}

    {:ok, first} = ETS.put(variant, server: server)
    Process.sleep(10)
    {:ok, second} = ETS.put(variant, server: server)

    assert first.inserted_at == second.inserted_at
    assert DateTime.compare(second.updated_at, first.updated_at) in [:eq, :gt]
    assert {:ok, ^second} = ETS.get("card", table: table)
  end

  test "delete/2 removes the variant", %{table: table, server: server} do
    {:ok, _} = ETS.put(%Variant{name: "tmp", pipeline: Pipeline.new()}, server: server)
    assert :ok = ETS.delete("tmp", server: server)
    assert {:error, :not_found} = ETS.get("tmp", table: table)
  end

  test "delete/2 returns :not_found for unknown names", %{server: server} do
    assert {:error, :not_found} = ETS.delete("nope", server: server)
  end

  test "list/1 returns every variant sorted by name", %{table: table, server: server} do
    {:ok, _} = ETS.put(%Variant{name: "z", pipeline: Pipeline.new()}, server: server)
    {:ok, _} = ETS.put(%Variant{name: "a", pipeline: Pipeline.new()}, server: server)

    {:ok, variants} = ETS.list(table: table)
    names = Enum.map(variants, & &1.name)

    # "public" is always present + the two we inserted
    assert "public" in names
    assert "a" in names
    assert "z" in names
    assert names == Enum.sort(names)
  end
end
