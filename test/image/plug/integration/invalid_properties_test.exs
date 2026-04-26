defmodule Image.Plug.Integration.InvalidPropertiesTest do
  @moduledoc """
  Inverse properties: every documented invalid value for an option
  key produces the matching `x-image-plug-error` tag and status code.

  Reproduce a failure with:

      STREAM_DATA_SEED=12345 mix test test/image/plug/integration/invalid_properties_test.exs
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Cloudflare, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  use ExUnitProperties

  import Image.Plug.TestGenerators

  defp request_status(path, base_url) do
    {:ok, response} = request(path, base_url: base_url)
    {response.status, response.headers["x-image-plug-error"]}
  end

  defp assert_invalid(path, base_url) do
    {status, [tag]} = request_status(path, base_url)
    assert status == 400
    assert tag == "invalid_option"
  end

  property "invalid width returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_width(), max_runs: 25 do
      assert_invalid("/cdn-cgi/image/width=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid height returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_height(), max_runs: 25 do
      assert_invalid("/cdn-cgi/image/height=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid fit returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_fit(), bad != "", max_runs: 25 do
      assert_invalid("/cdn-cgi/image/width=100,fit=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid format returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_format(), bad != "", max_runs: 25 do
      assert_invalid("/cdn-cgi/image/format=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid quality returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_quality(), max_runs: 25 do
      assert_invalid("/cdn-cgi/image/quality=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid metadata returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_metadata(), bad != "", max_runs: 25 do
      assert_invalid("/cdn-cgi/image/metadata=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid rotate returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_rotate(), max_runs: 25 do
      assert_invalid("/cdn-cgi/image/rotate=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid flip returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_flip(), bad != "", max_runs: 25 do
      assert_invalid("/cdn-cgi/image/flip=#{bad}/portrait.jpg", base_url)
    end
  end

  property "invalid gravity returns 400 :invalid_option", %{base_url: base_url} do
    check all bad <- invalid_gravity(), max_runs: 25 do
      assert_invalid("/cdn-cgi/image/width=100,gravity=#{bad}/portrait.jpg", base_url)
    end
  end

  property "unknown option key returns 400 :unknown_option", %{base_url: base_url} do
    check all key <- filter(string(:alphanumeric, min_length: 3, max_length: 8),
                            &(&1 not in known_keys())),
              value <- string(:alphanumeric, max_length: 5),
              max_runs: 25 do
      {status, [tag]} =
        request_status("/cdn-cgi/image/#{key}=#{value}/portrait.jpg", base_url)

      assert status == 400
      assert tag == "unknown_option"
    end
  end

  property "non-existent source path returns 404 :source_not_found", %{base_url: base_url} do
    check all stem <- string(:alphanumeric, min_length: 5, max_length: 12),
              max_runs: 15 do
      {status, [tag]} =
        request_status("/cdn-cgi/image/width=100/#{stem}.jpg", base_url)

      assert status == 404
      assert tag == "source_not_found"
    end
  end

  defp known_keys do
    [
      "width", "w",
      "height", "h",
      "fit",
      "gravity", "g",
      "dpr",
      "zoom", "face-zoom",
      "quality", "q",
      "format", "f",
      "metadata",
      "anim",
      "compression",
      "slow-connection-quality", "scq",
      "background",
      "blur",
      "sharpen",
      "brightness",
      "contrast",
      "gamma",
      "saturation",
      "rotate",
      "flip",
      "trim",
      "border",
      "segment",
      "onerror",
      "draw"
    ]
  end
end
