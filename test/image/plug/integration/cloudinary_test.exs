defmodule Image.Plug.Integration.CloudinaryTest do
  @moduledoc """
  End-to-end Cloudinary provider: stand up a Bandit configured with
  `Image.Plug.Provider.Cloudinary`, fire Cloudinary-style URLs,
  assert the pipeline runs and the bytes match.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Cloudinary, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  test "w + f produces an image of the right width + format", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/w_200,f_jpg/portrait.jpg", base_url: base_url)

    assert response.status == 200
    assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]
    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == 200
  end

  test "c_fill with explicit dims produces exact dims", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/w_150,h_150,c_fill,f_jpg/portrait.jpg",
        base_url: base_url
      )

    assert response.status == 200
    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == 150
    assert Image.height(decoded) == 150
  end

  test "f_auto respects Accept header", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/f_auto/portrait.jpg",
        base_url: base_url,
        headers: [{"accept", "image/webp"}]
      )

    assert response.status == 200
    assert response.headers["content-type"] == ["image/webp; charset=utf-8"]
  end

  test "multi-stage transforms flatten and run", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/w_200,c_fill/f_jpg/portrait.jpg", base_url: base_url)

    assert response.status == 200
    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == 200
  end

  test "no transform stage = passthrough source", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/portrait.jpg", base_url: base_url)

    assert response.status == 200
  end

  test "e_replace_color runs end-to-end and returns valid bytes", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/e_replace_color:white:50,f_jpg/portrait.jpg",
        base_url: base_url
      )

    assert response.status == 200
    assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]

    # Just confirm libvips returns a decodable image — pixel-level
    # before/after comparison would be an Image-library test, not an
    # image_plug test.
    assert {:ok, _decoded} = Image.from_binary(response.body)
  end

  test "unsupported e_vignette returns 400 :unsupported_option", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/e_vignette/portrait.jpg", base_url: base_url)

    assert response.status == 400
    assert response.headers["x-image-plug-error"] == ["unsupported_option"]
  end

  test "unknown key returns 400 :unknown_option", %{base_url: base_url} do
    {:ok, response} =
      request("/demo/image/upload/notarealkey_1/portrait.jpg", base_url: base_url)

    assert response.status == 400
    assert response.headers["x-image-plug-error"] == ["unknown_option"]
  end

  describe "signing (separate plug)" do
    @signing_keys ["cloudinary-integration-test-key"]

    setup do
      {:ok, server_pid} =
        Bandit.start_link(
          plug:
            {Image.Plug,
             [
               provider:
                 {Image.Plug.Provider.Cloudinary,
                  signing: %{keys: @signing_keys, required?: true}},
               source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
               on_error: :status_text
             ]},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

      on_exit(fn -> if Process.alive?(server_pid), do: Process.exit(server_pid, :shutdown) end)

      %{signed_base_url: "http://127.0.0.1:#{port}"}
    end

    test "unsigned URL → 401 :signature_required", %{signed_base_url: base_url} do
      {:ok, response} =
        Req.get(base_url <> "/demo/image/upload/w_200/portrait.jpg", decode_body: false)

      assert response.status == 401
      assert response.headers["x-image-plug-error"] == ["signature_required"]
    end

    test "validly-signed URL → 200", %{signed_base_url: base_url} do
      path = "/demo/image/upload/w_200,f_jpg/portrait.jpg"
      signed = Image.Plug.Provider.Cloudinary.Signing.sign(path, @signing_keys)

      {:ok, response} = Req.get(base_url <> signed, decode_body: false)
      assert response.status == 200
    end

    test "tampered signature → 401 :invalid_signature", %{signed_base_url: base_url} do
      path = "/demo/image/upload/w_200,f_jpg/portrait.jpg"
      signed = Image.Plug.Provider.Cloudinary.Signing.sign(path, @signing_keys)
      tampered = String.replace(signed, ~r{/s--[^/]+--/}, "/s--00000000--/")

      {:ok, response} = Req.get(base_url <> tampered, decode_body: false)
      assert response.status == 401
      assert response.headers["x-image-plug-error"] == ["invalid_signature"]
    end
  end
end
