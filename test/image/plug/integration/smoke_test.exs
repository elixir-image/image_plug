defmodule Image.Plug.Integration.SmokeTest do
  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Cloudflare, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  test "harness boots and serves a transformed image over real HTTP", %{base_url: base_url} do
    assert {:ok, response} =
             request("/cdn-cgi/image/width=100,format=jpeg/portrait.jpg", base_url: base_url)

    assert response.status == 200
    assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]
    assert binary_part(response.body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
  end

  test "malformed URL surfaces the error tag at the wire", %{base_url: base_url} do
    # A cdn-cgi/image URL missing its source segment is a genuine
    # malformed image request (a non-image path passes through instead).
    assert {:ok, response} = request("/cdn-cgi/image/width=50", base_url: base_url)
    assert response.status == 400
    assert response.headers["x-image-plug-error"] == ["malformed_url"]
  end
end
