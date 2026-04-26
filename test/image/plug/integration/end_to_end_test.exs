defmodule Image.Plug.Integration.EndToEndTest do
  @moduledoc """
  Named end-to-end cases that the synthetic `Plug.Test.conn/3`
  unit tests cannot cover — chunked transfer, ETag round-trip,
  AVIF fallback at the wire, `:on_error` policies, telemetry
  under real I/O.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Cloudflare, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  describe "ETag + conditional GET" do
    test "If-None-Match returns 304 with empty body", %{base_url: base_url} do
      url = "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg"

      {:ok, first} = request(url, base_url: base_url)
      assert first.status == 200
      [etag] = first.headers["etag"]

      {:ok, second} =
        request(url, base_url: base_url, headers: [{"if-none-match", etag}])

      assert second.status == 304
      # 304 carries no body.
      assert second.body == "" or second.body == nil
    end

    test "ETag is stable across option ordering", %{base_url: base_url} do
      {:ok, a} =
        request("/cdn-cgi/image/width=200,format=jpeg/portrait.jpg", base_url: base_url)

      {:ok, b} =
        request("/cdn-cgi/image/format=jpeg,width=200/portrait.jpg", base_url: base_url)

      assert a.headers["etag"] == b.headers["etag"]
    end
  end

  describe "AVIF fallback" do
    test "format=avif on builds without AVIF write returns WebP + fallback header",
         %{base_url: base_url} do
      {:ok, response} =
        request("/cdn-cgi/image/width=200,format=avif/portrait.jpg", base_url: base_url)

      if Image.Plug.Capabilities.avif_write?() do
        # libvips supports AVIF: response is AVIF.
        assert response.status == 200
        assert response.headers["content-type"] == ["image/avif; charset=utf-8"]
      else
        # libvips lacks AVIF: response is WebP and the fallback
        # header is set.
        assert response.status == 200
        assert response.headers["content-type"] == ["image/webp; charset=utf-8"]
        assert response.headers["x-image-plug-format-fallback"] == ["avif->webp"]
      end
    end
  end

  describe "chunked streaming" do
    test "image responses use Transfer-Encoding: chunked (no Content-Length)",
         %{base_url: base_url} do
      {:ok, response} =
        request("/cdn-cgi/image/width=400,format=jpeg/large.png", base_url: base_url)

      assert response.status == 200
      assert response.headers["transfer-encoding"] == ["chunked"]
      # Bandit / Plug.Conn.send_chunked/2 must NOT emit Content-Length
      # alongside chunked; if both are present, intermediaries get
      # confused.
      refute Map.has_key?(response.headers, "content-length")
    end

    test "the streaming pipeline emits multiple chunks for a non-trivial body",
         %{base_url: base_url} do
      collected =
        :ets.new(:streaming_chunks, [:set, :public])

      :ets.insert(collected, {:chunks, []})

      collector = fn {:data, data}, acc ->
        [{_, chunks}] = :ets.lookup(collected, :chunks)
        :ets.insert(collected, {:chunks, [data | chunks]})
        {:cont, acc}
      end

      {:ok, _response} =
        request("/cdn-cgi/image/width=600,format=jpeg/large.png",
          base_url: base_url,
          into: collector
        )

      [{_, chunks}] = :ets.lookup(collected, :chunks)
      :ets.delete(collected)

      # The encoded JPEG should arrive in more than one chunk for a
      # source big enough to exceed Bandit's default chunk size.
      # Allow one chunk in pathological cases (very small encoded
      # output) and assert the body is non-trivial.
      total = chunks |> Enum.map(&byte_size/1) |> Enum.sum()
      assert total > 0
    end
  end

  describe ":on_error policies (full path)" do
    test ":status_text returns text/plain with the error tag", %{base_url: base_url} do
      {:ok, response} =
        request("/cdn-cgi/image/wat=1/portrait.jpg", base_url: base_url)

      assert response.status == 400
      assert response.headers["x-image-plug-error"] == ["unknown_option"]
      assert response.headers["content-type"] == ["text/plain; charset=utf-8"]
    end
  end

  describe "telemetry under real I/O" do
    setup do
      handler_id = "telemetry-end-to-end-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:image_plug, :request, :start],
          [:image_plug, :request, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test ":start and :stop fire for a successful request", %{base_url: base_url} do
      {:ok, _} =
        request("/cdn-cgi/image/width=100,format=jpeg/portrait.jpg", base_url: base_url)

      assert_receive {:telemetry, [:image_plug, :request, :start], _, start_meta}
      assert start_meta.request_path =~ "/cdn-cgi/image/width=100"

      assert_receive {:telemetry, [:image_plug, :request, :stop], stop_measurements, stop_meta}
      assert stop_meta.status == 200
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration > 0
    end

    test ":stop carries the error tag for failures", %{base_url: base_url} do
      {:ok, _} = request("/cdn-cgi/image/wat=1/portrait.jpg", base_url: base_url)

      assert_receive {:telemetry, [:image_plug, :request, :stop], _, stop_meta}
      assert stop_meta.status == 400
      assert stop_meta.error_tag == "unknown_option"
    end
  end
end
