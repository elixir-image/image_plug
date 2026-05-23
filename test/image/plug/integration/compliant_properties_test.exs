defmodule Image.Plug.Integration.CompliantPropertiesTest do
  @moduledoc """
  Property-based assertions: for every documented option key, any
  value within the documented range produces a 200 response with
  the expected effect.

  Reproduce a failure with:

      STREAM_DATA_SEED=12345 mix test test/image/plug/integration/compliant_properties_test.exs
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Cloudflare, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  use ExUnitProperties

  import Image.Plug.TestGenerators

  defp fetch_image(path, base_url, headers \\ []) do
    {:ok, response} = request(path, base_url: base_url, headers: headers)
    response
  end

  property "width=N produces an image of decoded width N", %{base_url: base_url} do
    check all(width <- valid_width(), max_runs: 25) do
      response =
        fetch_image(
          "/cdn-cgi/image/width=#{width},format=jpeg,fit=cover,height=#{width}/landscape.jpg",
          base_url
        )

      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      assert Image.width(decoded) == width
    end
  end

  property "height=N produces an image of decoded height N", %{base_url: base_url} do
    check all(height <- valid_height(), max_runs: 25) do
      response =
        fetch_image(
          "/cdn-cgi/image/width=#{height},height=#{height},fit=cover,format=jpeg/landscape.jpg",
          base_url
        )

      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      assert Image.height(decoded) == height
    end
  end

  property "fit=scale_down never produces an output wider than the source", %{base_url: base_url} do
    # landscape.jpg is wider than 4000px (Sydney-Opera-House is
    # 1920x1080-ish; using 50..2000 stays comfortably inside the
    # source width, then 8000 confirms the cap).
    {:ok, source} = Image.open(Path.join(@fixtures, "landscape.jpg"))
    source_width = Image.width(source)

    check all(
            width <-
              one_of([integer(50..source_width), integer((source_width + 1)..(source_width * 2))]),
            max_runs: 25
          ) do
      response =
        fetch_image(
          "/cdn-cgi/image/width=#{width},fit=scale-down,format=jpeg/landscape.jpg",
          base_url
        )

      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      # Either the user-requested width (if it didn't exceed the source)
      # or the source width (if scale_down clamped). Either way it must
      # never exceed the source.
      assert Image.width(decoded) <= source_width
    end
  end

  property "format=jpeg produces JPEG magic bytes", %{base_url: base_url} do
    check all(width <- integer(50..400), max_runs: 25) do
      response =
        fetch_image("/cdn-cgi/image/width=#{width},format=jpeg/portrait.jpg", base_url)

      assert response.status == 200
      assert response.headers["content-type"] == ["image/jpeg; charset=utf-8"]
      assert binary_part(response.body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end
  end

  property "format=png produces PNG magic bytes", %{base_url: base_url} do
    check all(width <- integer(50..400), max_runs: 25) do
      response =
        fetch_image("/cdn-cgi/image/width=#{width},format=png/portrait.jpg", base_url)

      assert response.status == 200
      assert response.headers["content-type"] == ["image/png; charset=utf-8"]
      assert binary_part(response.body, 0, 4) == <<0x89, "PNG">>
    end
  end

  property "format=webp produces WebP magic bytes", %{base_url: base_url} do
    check all(width <- integer(50..400), max_runs: 25) do
      response =
        fetch_image("/cdn-cgi/image/width=#{width},format=webp/portrait.jpg", base_url)

      assert response.status == 200
      assert response.headers["content-type"] == ["image/webp; charset=utf-8"]
      assert binary_part(response.body, 0, 4) == "RIFF"
    end
  end

  property "rotate=90 swaps width and height", %{base_url: base_url} do
    # landscape.jpg has aspect-ratio > 1 (wider than tall). After
    # rotate=90 the output's height should exceed its width.
    check all(width <- integer(50..200), max_runs: 25) do
      response =
        fetch_image(
          "/cdn-cgi/image/width=#{width},rotate=90,format=jpeg/landscape.jpg",
          base_url
        )

      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      # rotate=90 swaps the source's W:H so the output is taller
      # than wide.
      assert Image.height(decoded) > Image.width(decoded)
    end
  end

  property "flip=h preserves dimensions", %{base_url: base_url} do
    check all(width <- integer(50..200), max_runs: 25) do
      response =
        fetch_image(
          "/cdn-cgi/image/width=#{width},height=#{width},fit=cover,flip=h,format=jpeg/portrait.jpg",
          base_url
        )

      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      assert Image.width(decoded) == width
      assert Image.height(decoded) == width
    end
  end

  property "dpr=N multiplies dimensions by N", %{base_url: base_url} do
    check all(width <- integer(50..200), dpr <- integer(1..3), max_runs: 25) do
      response =
        fetch_image(
          "/cdn-cgi/image/width=#{width},height=#{width},fit=cover,dpr=#{dpr},format=jpeg/portrait.jpg",
          base_url
        )

      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      assert Image.width(decoded) == width * dpr
      assert Image.height(decoded) == width * dpr
    end
  end

  property "format=auto with Accept: image/webp returns WebP", %{base_url: base_url} do
    check all(width <- integer(50..200), max_runs: 15) do
      response =
        fetch_image(
          "/cdn-cgi/image/width=#{width},format=auto/portrait.jpg",
          base_url,
          [{"accept", "image/webp"}]
        )

      assert response.status == 200
      assert response.headers["content-type"] == ["image/webp; charset=utf-8"]
    end
  end
end
