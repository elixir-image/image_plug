defmodule Image.Plug.VariantStore.Persistence.FileTest do
  use ExUnit.Case, async: false

  alias Image.Plug.VariantStore.ETS.Server, as: ETSServer
  alias Image.Plug.VariantStore.Persistence.File, as: FilePersistence

  setup do
    dir =
      System.tmp_dir!()
      |> Path.join("image_plug_persistence_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "variants.json")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{path: path}
  end

  describe "load/1 — first boot" do
    test "returns {:ok, []} when the file does not exist", %{path: path} do
      assert {:ok, []} = FilePersistence.load(path: path)
    end
  end

  describe "round-trip via the ETS server" do
    test "variants put before restart are still present after restart", %{path: path} do
      # First boot: create + put a variant.
      table = :"persist_test_#{System.unique_integer([:positive])}"
      server_a = :"#{table}_server_a"

      {:ok, pid_a} =
        ETSServer.start_link(
          name: server_a,
          table: table,
          persistence: {FilePersistence, path: path}
        )

      {:ok, _} =
        Image.Plug.put_variant(
          "thumbnail",
          "width=200,height=200,fit=cover,format=webp",
          server: server_a,
          table: table
        )

      # Stop the server (and drop the ETS table — :ets is owned by the
      # GenServer; gone when the process exits).
      GenServer.stop(pid_a)

      # Re-create the server with the same persistence config; the
      # variant should hydrate from disk.
      table_b = :"persist_test_b_#{System.unique_integer([:positive])}"
      server_b = :"#{table_b}_server_b"

      {:ok, pid_b} =
        ETSServer.start_link(
          name: server_b,
          table: table_b,
          persistence: {FilePersistence, path: path}
        )

      assert {:ok, variant} =
               Image.Plug.get_variant("thumbnail", table: table_b, server: server_b)

      assert variant.name == "thumbnail"
      assert variant.options == "width=200,height=200,fit=cover,format=webp"

      GenServer.stop(pid_b)
    end

    test "delete also persists", %{path: path} do
      table = :"persist_delete_#{System.unique_integer([:positive])}"
      server = :"#{table}_server"

      {:ok, pid} =
        ETSServer.start_link(
          name: server,
          table: table,
          persistence: {FilePersistence, path: path}
        )

      {:ok, _} = Image.Plug.put_variant("a", "width=100", server: server, table: table)
      {:ok, _} = Image.Plug.put_variant("b", "width=200", server: server, table: table)
      :ok = Image.Plug.delete_variant("a", server: server, table: table)

      GenServer.stop(pid)

      table_b = :"persist_delete_b_#{System.unique_integer([:positive])}"
      server_b = :"#{table_b}_server_b"

      {:ok, pid_b} =
        ETSServer.start_link(
          name: server_b,
          table: table_b,
          persistence: {FilePersistence, path: path}
        )

      assert {:error, :not_found} =
               Image.Plug.get_variant("a", table: table_b, server: server_b)

      assert {:ok, _} = Image.Plug.get_variant("b", table: table_b, server: server_b)

      GenServer.stop(pid_b)
    end
  end

  describe "persistable filtering" do
    test "skips variants with no :options string (programmatic pipelines)", %{path: path} do
      table = :"persist_skip_#{System.unique_integer([:positive])}"
      server = :"#{table}_server"

      {:ok, pid} =
        ETSServer.start_link(
          name: server,
          table: table,
          persistence: {FilePersistence, path: path}
        )

      # Put a Variant with no options string (built from a Pipeline
      # directly).
      pipeline = Image.Plug.Pipeline.new()
      variant = %Image.Plug.Variant{name: "programmatic", pipeline: pipeline, options: nil}
      {:ok, _} = Image.Plug.put_variant(variant, server: server, table: table)

      # Put a normal options-string-backed variant.
      {:ok, _} = Image.Plug.put_variant("normal", "width=200", server: server, table: table)

      # Read the persisted JSON: should contain "normal" but not "programmatic".
      json = File.read!(path) |> :json.decode()
      names = Enum.map(json, & &1["name"])

      assert "normal" in names
      refute "programmatic" in names

      GenServer.stop(pid)
    end
  end

  describe "load/1 corruption handling" do
    test "non-JSON file returns {:error, _}", %{path: path} do
      File.write!(path, "this is not json")
      assert {:error, _} = FilePersistence.load(path: path)
    end

    test "JSON root that's not an array returns {:error, _}", %{path: path} do
      File.write!(path, ~s({"oops": "object"}))
      assert {:error, :json_root_must_be_array} = FilePersistence.load(path: path)
    end

    test "individual malformed entries are skipped (other entries load)", %{path: path} do
      File.write!(path, ~s([
        {"name": "good", "options": "width=200"},
        {"name": "bad-no-options"},
        "not-even-an-object"
      ]))

      assert {:ok, [variant]} = FilePersistence.load(path: path)
      assert variant.name == "good"
    end
  end
end
