defmodule Image.Plug.Integration.OnErrorTest do
  @moduledoc """
  End-to-end coverage of the `:on_error` policies under real HTTP.
  Each policy spins up its own Bandit instance because the policy
  is fixed at `init/1` time.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use ExUnit.Case, async: false

  defp start_plug(on_error) do
    {:ok, server_pid} =
      Bandit.start_link(
        plug:
          {Image.Plug,
           [
             provider: {Image.Plug.Provider.Cloudflare, []},
             source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
             on_error: on_error
           ]},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :shutdown)
    end)

    "http://127.0.0.1:#{port}"
  end

  describe ":render_error_image" do
    test "malformed URL returns a 200 PNG placeholder" do
      base_url = start_plug(:render_error_image)

      {:ok, response} = Req.get(base_url <> "/cdn-cgi/image/width=50", decode_body: false)

      assert response.status == 200
      assert response.headers["content-type"] == ["image/png; charset=utf-8"]
      assert response.headers["x-image-plug-error"] == ["malformed_url"]
      assert response.headers["cache-control"] == ["no-store"]
      # PNG magic bytes.
      assert binary_part(response.body, 0, 4) == <<0x89, "PNG">>
    end

    test "unknown option also produces a placeholder PNG" do
      base_url = start_plug(:render_error_image)

      {:ok, response} =
        Req.get(base_url <> "/cdn-cgi/image/wat=1/portrait.jpg", decode_body: false)

      assert response.status == 200
      assert response.headers["content-type"] == ["image/png; charset=utf-8"]
      assert response.headers["x-image-plug-error"] == ["unknown_option"]
    end
  end

  describe ":fallback_to_source" do
    test "falls back to source bytes when source loaded but pipeline failed" do
      base_url = start_plug(:fallback_to_source)

      # Build a request that loads `portrait.jpg` then fails the
      # interpreter (Draw with a no-resolver source). Under
      # `:fallback_to_source` the response is the source re-encoded
      # in its source format (JPEG) with `cache-control: no-store`
      # and the error tag header.
      inner = URI.encode("url(https://example.com/wm.png)", &URI.char_unreserved?/1)
      url = base_url <> "/cdn-cgi/image/draw=#{inner},format=jpeg/portrait.jpg"

      {:ok, response} = Req.get(url, decode_body: false)

      assert response.status == 200
      assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]
      assert response.headers["cache-control"] == ["no-store"]
      [error_tag] = response.headers["x-image-plug-error"]
      assert is_binary(error_tag)
      assert binary_part(response.body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test "falls through to the error status when source fails to load" do
      base_url = start_plug(:fallback_to_source)

      {:ok, response} =
        Req.get(base_url <> "/cdn-cgi/image/width=200/missing.jpg", decode_body: false)

      assert response.status == 404
    end
  end
end
