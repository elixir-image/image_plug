defmodule Image.Plug.Integration.ImgixTest do
  @moduledoc """
  End-to-end imgix provider: stand up a Bandit configured with
  `Image.Plug.Provider.Imgix`, fire imgix-style URLs, assert the
  pipeline runs and the bytes match.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Imgix, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  test "w + fm produces an image of the right width + format", %{base_url: base_url} do
    {:ok, response} = request("/portrait.jpg?w=200&fm=jpeg", base_url: base_url)

    assert response.status == 200
    assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]
    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == 200
  end

  test "fit=crop with explicit dims produces exact dims", %{base_url: base_url} do
    {:ok, response} = request("/portrait.jpg?w=150&h=150&fit=crop&fm=jpeg", base_url: base_url)

    assert response.status == 200
    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == 150
    assert Image.height(decoded) == 150
  end

  test "auto=format,compress respects Accept header", %{base_url: base_url} do
    {:ok, response} =
      request("/portrait.jpg?auto=format,compress",
        base_url: base_url,
        headers: [{"accept", "image/webp"}]
      )

    assert response.status == 200
    assert response.headers["content-type"] == ["image/webp; charset=utf-8"]
  end

  test "monochrome= produces a single-channel image (B&W)", %{base_url: base_url} do
    {:ok, response} = request("/portrait.jpg?monochrome=ff0000&fm=jpeg", base_url: base_url)

    assert response.status == 200
    assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]

    {:ok, decoded} = Image.from_binary(response.body)
    # JPEG decode of a B&W source produces a single-channel image.
    assert Image.bands(decoded) == 1
  end

  test "cs=srgb converts the colorspace and returns valid bytes", %{base_url: base_url} do
    {:ok, response} = request("/portrait.jpg?cs=srgb&fm=jpeg", base_url: base_url)

    assert response.status == 200
    assert {:ok, _decoded} = Image.from_binary(response.body)
  end

  test "unsupported sepia returns 400 :unsupported_option", %{base_url: base_url} do
    {:ok, response} = request("/portrait.jpg?sepia=80", base_url: base_url)

    assert response.status == 400
    assert response.headers["x-image-plug-error"] == ["unsupported_option"]
  end

  test "unknown key returns 400 :unknown_option", %{base_url: base_url} do
    {:ok, response} = request("/portrait.jpg?foo=bar", base_url: base_url)

    assert response.status == 400
    assert response.headers["x-image-plug-error"] == ["unknown_option"]
  end

  describe "signing (separate plug)" do
    @signing_keys ["imgix-integration-test-key"]

    setup do
      {:ok, server_pid} =
        Bandit.start_link(
          plug:
            {Image.Plug,
             [
               provider:
                 {Image.Plug.Provider.Imgix,
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
      {:ok, response} = Req.get(base_url <> "/portrait.jpg?w=200&fm=jpeg", decode_body: false)
      assert response.status == 401
      assert response.headers["x-image-plug-error"] == ["signature_required"]
    end

    test "validly-signed URL → 200", %{signed_base_url: base_url} do
      path = "/portrait.jpg?w=200&fm=jpeg"
      signed = Image.Plug.Provider.Imgix.Signing.sign(path, @signing_keys)

      {:ok, response} = Req.get(base_url <> signed, decode_body: false)
      assert response.status == 200
    end

    test "tampered signature → 401 :invalid_signature", %{signed_base_url: base_url} do
      path = "/portrait.jpg?w=200&fm=jpeg"
      signed = Image.Plug.Provider.Imgix.Signing.sign(path, @signing_keys)
      tampered = String.replace(signed, "&s=", "&s=00000000")

      {:ok, response} = Req.get(base_url <> tampered, decode_body: false)
      assert response.status == 401
      assert response.headers["x-image-plug-error"] == ["invalid_signature"]
    end
  end
end
