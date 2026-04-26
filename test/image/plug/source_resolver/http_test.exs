defmodule Image.Plug.SourceResolver.HTTPTest do
  use ExUnit.Case, async: false

  alias Image.Plug.{Error, Source}
  alias Image.Plug.SourceResolver.HTTP

  @fixture Path.expand("../../../fixtures/images/sample.jpg", __DIR__)

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, port: bypass.port}
  end

  test "streams a JPEG from the configured host", %{bypass: bypass, port: port} do
    bytes = File.read!(@fixture)

    Bypass.expect_once(bypass, "GET", "/sample.jpg", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.resp(200, bytes)
    end)

    {:ok, source} = Source.url("http://localhost:#{port}/sample.jpg")

    assert {:ok, image, meta} =
             HTTP.load(source, allowed_hosts: ["localhost"])

    assert match?(%Vix.Vips.Image{}, image)
    assert meta.content_type == "image/jpeg"
    assert is_binary(meta.etag_seed)
  end

  test "rejects hosts not on the allow-list", %{port: port} do
    {:ok, source} = Source.url("http://localhost:#{port}/sample.jpg")

    assert {:error, %Error{tag: :invalid_option}} =
             HTTP.load(source, allowed_hosts: ["other.example"])
  end

  test "rejects non-:url sources" do
    hosted = Source.hosted("acct", "id")

    assert {:error, %Error{tag: :invalid_option, details: %{got_kind: :hosted}}} =
             HTTP.load(hosted, allowed_hosts: :any)
  end

  test "surfaces a fetch error when the upstream is down", %{bypass: bypass, port: port} do
    Bypass.down(bypass)

    {:ok, source} = Source.url("http://localhost:#{port}/sample.jpg")

    assert {:error, %Error{tag: :source_fetch_error}} =
             HTTP.load(source, allowed_hosts: :any)
  end
end
