defmodule Image.Plug.Integration.VariantsTest do
  @moduledoc """
  End-to-end variant resolution: seed a variant, fetch the hosted
  URL form, assert the response matches the seeded transform.

  Uses an isolated `VariantStore.ETS` instance per test module so
  the seed doesn't leak into the application-level singleton store
  used by other integration tests.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use ExUnit.Case, async: false

  defmodule HostedFileResolver do
    @moduledoc false
    # Test-only: maps `{_account, image_id}` to a file under the
    # configured root.
    @behaviour Image.Plug.SourceResolver

    @impl true
    def load(%Image.Plug.Source{kind: :hosted, ref: {_account, image_id}}, options) do
      {:ok, path_source} = Image.Plug.Source.path("/" <> image_id)
      Image.Plug.SourceResolver.File.load(path_source, options)
    end
  end

  setup_all do
    table = :"variants_integration_#{System.unique_integer([:positive])}"
    server = :"#{table}_server"

    {:ok, store_pid} =
      Image.Plug.VariantStore.ETS.Server.start_link(
        name: server,
        table: table,
        seed: []
      )

    {:ok, _} =
      Image.Plug.put_variant(
        "thumbnail",
        "width=120,height=120,fit=cover,format=jpeg",
        table: table,
        server: server
      )

    {:ok, server_pid} =
      Bandit.start_link(
        plug:
          {Image.Plug,
           [
             provider: {Image.Plug.Provider.Cloudflare, hosted_account_hash: "acct"},
             source_resolver:
               {Image.Plug.SourceResolver.Composite,
                file: [root: @fixtures], hosted: {HostedFileResolver, root: @fixtures}},
             variant_store: {Image.Plug.VariantStore.ETS, [table: table, server: server]},
             on_error: :status_text
           ]},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :shutdown)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    {:ok, %{base_url: "http://127.0.0.1:#{port}", port: port}}
  end

  test "hosted URL with a known variant returns the seeded transform", %{base_url: base_url} do
    {:ok, response} = Req.get(base_url <> "/acct/portrait.jpg/thumbnail", decode_body: false)

    assert response.status == 200
    assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]

    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == 120
    assert Image.height(decoded) == 120
  end

  test "implicit `public` variant always resolves", %{base_url: base_url} do
    {:ok, response} = Req.get(base_url <> "/acct/portrait.jpg", decode_body: false)
    assert response.status == 200
  end

  test "unknown variant returns 404 with the right error tag", %{base_url: base_url} do
    {:ok, response} =
      Req.get(base_url <> "/acct/portrait.jpg/no-such-variant", decode_body: false)

    assert response.status == 404
    assert response.headers["x-image-plug-error"] == ["variant_not_found"]
  end
end
