defmodule Image.Plug.AdminTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  setup do
    table = :"admin_test_#{System.unique_integer([:positive])}"
    name = :"#{table}_server"

    {:ok, pid} =
      Image.Plug.VariantStore.ETS.Server.start_link(name: name, table: table, seed: [])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    plug_options =
      Image.Plug.Admin.init(
        provider: Image.Plug.Provider.Cloudflare,
        variant_store: {Image.Plug.VariantStore.ETS, [table: table, server: name]}
      )

    %{plug_options: plug_options}
  end

  defp call(method, path, body, plug_options) do
    body_iodata =
      case body do
        nil -> ""
        binary when is_binary(binary) -> binary
        map when is_map(map) -> IO.iodata_to_binary(:json.encode(map))
      end

    method
    |> conn(path, body_iodata)
    |> put_req_header("content-type", "application/json")
    |> Image.Plug.Admin.call(plug_options)
  end

  defp decode(conn) do
    :json.decode(conn.resp_body)
  end

  test "GET / lists variants", %{plug_options: plug_options} do
    conn = call(:get, "/", nil, plug_options)
    assert conn.status == 200

    %{"result" => result} = decode(conn)
    names = Enum.map(result, & &1["name"])
    assert "public" in names
  end

  test "POST / creates a new variant", %{plug_options: plug_options} do
    body = %{"name" => "thumb", "options" => "width=100,fit=cover"}
    conn = call(:post, "/", body, plug_options)
    assert conn.status == 201

    decoded = decode(conn)
    assert decoded["name"] == "thumb"
    assert decoded["options"] == "width=100,fit=cover"
    assert is_list(decoded["ops"])
  end

  test "POST / errors 409 on conflict", %{plug_options: plug_options} do
    body = %{"name" => "dup", "options" => "width=100"}
    assert call(:post, "/", body, plug_options).status == 201
    conn = call(:post, "/", body, plug_options)
    assert conn.status == 409
    assert get_resp_header(conn, "x-image-plug-error") == ["variant_already_exists"]
  end

  test "POST / errors 400 on missing name", %{plug_options: plug_options} do
    conn = call(:post, "/", %{"options" => "width=100"}, plug_options)
    assert conn.status == 400
  end

  test "POST / errors 400 on bad options", %{plug_options: plug_options} do
    conn = call(:post, "/", %{"name" => "bad", "options" => "wat=1"}, plug_options)
    assert conn.status == 400
    assert get_resp_header(conn, "x-image-plug-error") == ["unknown_option"]
  end

  test "GET /:name returns the variant", %{plug_options: plug_options} do
    _ = call(:put, "/foo", %{"options" => "width=100"}, plug_options)
    conn = call(:get, "/foo", nil, plug_options)
    assert conn.status == 200
    assert decode(conn)["name"] == "foo"
  end

  test "GET /:name 404s for unknown", %{plug_options: plug_options} do
    conn = call(:get, "/nope", nil, plug_options)
    assert conn.status == 404
    assert get_resp_header(conn, "x-image-plug-error") == ["variant_not_found"]
  end

  test "PUT /:name upserts", %{plug_options: plug_options} do
    conn = call(:put, "/up", %{"options" => "width=200"}, plug_options)
    assert conn.status == 200

    conn = call(:put, "/up", %{"options" => "width=300"}, plug_options)
    assert conn.status == 200

    body = decode(call(:get, "/up", nil, plug_options))
    assert body["options"] == "width=300"
  end

  test "PATCH /:name partially updates", %{plug_options: plug_options} do
    _ = call(:put, "/p", %{"options" => "width=100", "metadata" => %{"a" => 1}}, plug_options)

    conn = call(:patch, "/p", %{"metadata" => %{"a" => 2}}, plug_options)
    assert conn.status == 200

    body = decode(call(:get, "/p", nil, plug_options))
    assert body["metadata"] == %{"a" => 2}
    assert body["options"] == "width=100"
  end

  test "PATCH /:name 404s for unknown", %{plug_options: plug_options} do
    conn = call(:patch, "/nope", %{}, plug_options)
    assert conn.status == 404
  end

  test "DELETE /:name removes", %{plug_options: plug_options} do
    _ = call(:put, "/d", %{"options" => "width=10"}, plug_options)
    conn = call(:delete, "/d", nil, plug_options)
    assert conn.status == 200

    assert call(:get, "/d", nil, plug_options).status == 404
  end

  test "DELETE /:name 404s for unknown", %{plug_options: plug_options} do
    conn = call(:delete, "/nope", nil, plug_options)
    assert conn.status == 404
  end

  test "rejects unknown routes with 400 :malformed_url", %{plug_options: plug_options} do
    conn = call(:post, "/foo/bar/baz", %{}, plug_options)
    assert conn.status == 400
  end

  test "rejects malformed JSON body", %{plug_options: plug_options} do
    conn = call(:post, "/", "{bad json", plug_options)
    assert conn.status == 400
    assert get_resp_header(conn, "x-image-plug-error") == ["invalid_option"]
  end
end
