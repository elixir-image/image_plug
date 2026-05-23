defmodule Image.Plug.Integration.HTTPSourceTest do
  @moduledoc """
  End-to-end test for `Image.Plug.SourceResolver.HTTP`. Uses Bypass
  to stand up a real upstream HTTP origin, mounts an `Image.Plug`
  configured with the HTTP resolver allow-listed at `localhost`,
  and asserts the streaming HTTP source path works under real I/O.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use ExUnit.Case, async: false

  setup do
    bypass = Bypass.open()

    {:ok, server_pid} =
      Bandit.start_link(
        plug:
          {Image.Plug,
           [
             provider: {Image.Plug.Provider.Cloudflare, []},
             source_resolver:
               {Image.Plug.SourceResolver.Composite, http: [allowed_hosts: ["localhost"]]},
             on_error: :status_text
           ]},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :shutdown)
    end)

    %{bypass: bypass, base_url: "http://127.0.0.1:#{port}"}
  end

  test "fetches a remote source over HTTP and serves the transformed image",
       %{bypass: bypass, base_url: base_url} do
    bytes = File.read!(Path.join(@fixtures, "portrait.jpg"))

    Bypass.expect_once(bypass, "GET", "/portrait.jpg", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.resp(200, bytes)
    end)

    upstream_url = "http://localhost:#{bypass.port}/portrait.jpg"
    encoded = URI.encode(upstream_url, &URI.char_unreserved?/1)
    request_path = "/cdn-cgi/image/width=80,format=jpeg/#{encoded}"

    {:ok, response} = Req.get(base_url <> request_path, decode_body: false)

    assert response.status == 200
    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == 80
  end

  test "host not on the allow-list returns 400 :invalid_option", %{base_url: base_url} do
    upstream_url = "http://other.example/x.jpg"
    encoded = URI.encode(upstream_url, &URI.char_unreserved?/1)
    request_path = "/cdn-cgi/image/width=80/#{encoded}"

    {:ok, response} = Req.get(base_url <> request_path, decode_body: false)

    assert response.status == 400
    assert response.headers["x-image-plug-error"] == ["invalid_option"]
  end
end
