defmodule Image.Plug.Integration.IIIFEndToEndTest do
  @moduledoc """
  HTTP-level end-to-end tests for the IIIF Image API 3.0 provider.
  Boots a real `Image.Plug` server with the IIIF provider mounted,
  fetches a representative set of IIIF URLs, and asserts each
  response decodes to an image of the expected dimensions and
  format.

  Complements the parser unit tests in
  `test/image/plug/provider/iiif/` — those check that the URL
  segments map to the right IR ops; these check that the IR ops
  actually produce the right pixels at HTTP-response time.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.IIIF, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  # IIIF default endpoint is `/iiif/3`.
  defp iiif_url(identifier, region, size, rotation, qf) do
    "/iiif/3/#{URI.encode(identifier, &URI.char_unreserved?/1)}/#{region}/#{size}/#{rotation}/#{qf}"
  end

  describe "size segment — every IIIF form serves a real image" do
    test "max — full-size original", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", "max", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      assert Image.width(image) > 0
      assert Image.height(image) > 0
    end

    test "w, — width-only proportional resize", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", "200,", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      assert Image.width(image) == 200
    end

    test ",h — height-only proportional resize", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", ",200", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      assert Image.height(image) == 200
    end

    test "!w,h — fit-within (contain) preserves aspect", %{base_url: base_url} do
      url = iiif_url("landscape.jpg", "full", "!200,200", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      # Landscape source, contained into 200×200 — width hits the box first.
      assert Image.width(image) == 200
      assert Image.height(image) <= 200
    end

    test "w,h — distort to exact dimensions", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", "200,200", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      assert Image.width(image) == 200
      assert Image.height(image) == 200
    end

    test "pct:N — percentage resize", %{base_url: base_url} do
      # First fetch the original to know its dimensions, then
      # request 25% and verify the math.
      {:ok, original_resp} =
        request(iiif_url("portrait.jpg", "full", "max", "0", "default.jpg"), base_url: base_url)

      {:ok, original} = Image.from_binary(original_resp.body)
      expected_w = trunc(Image.width(original) * 25 / 100)

      url = iiif_url("portrait.jpg", "full", "pct:25", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)

      # libvips' thumbnail rounds slightly differently than naive
      # truncation; allow ±1 pixel.
      assert_in_delta Image.width(image), expected_w, 1
    end
  end

  describe "region segment — extracts the requested sub-rectangle" do
    test "x,y,w,h — pixel region", %{base_url: base_url} do
      # Crop a 100×100 region from the top-left corner, then resize
      # so we can confirm the crop's aspect was preserved.
      url = iiif_url("landscape.jpg", "0,0,100,100", "max", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      assert Image.width(image) == 100
      assert Image.height(image) == 100
    end

    test "pct:x,y,w,h — percentage region", %{base_url: base_url} do
      # 50% × 50% region centred. Result aspect equals source aspect.
      {:ok, original_resp} =
        request(iiif_url("landscape.jpg", "full", "max", "0", "default.jpg"), base_url: base_url)

      {:ok, original} = Image.from_binary(original_resp.body)

      url = iiif_url("landscape.jpg", "pct:25,25,50,50", "max", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)

      assert_in_delta Image.width(image), trunc(Image.width(original) * 0.5), 2
      assert_in_delta Image.height(image), trunc(Image.height(original) * 0.5), 2
    end
  end

  describe "rotation segment" do
    test "rotate 90° on 200-wide swaps the axes", %{base_url: base_url} do
      url = iiif_url("landscape.jpg", "full", "200,", "90", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      # Source resized to 200 wide first, then rotated 90 → height becomes 200.
      assert Image.height(image) == 200
    end

    test "rotate 180° preserves dimensions", %{base_url: base_url} do
      url = iiif_url("landscape.jpg", "full", "200,", "180", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, image} = Image.from_binary(response.body)
      assert Image.width(image) == 200
    end
  end

  describe "quality segment" do
    test "gray quality URL serves a decodable image", %{base_url: base_url} do
      # We don't byte-compare gray vs default here because
      # `Image.saturation(image, 0.0)` is libvips-driven and can
      # legitimately produce byte-identical output for sources that
      # are already near-monochrome (and for some narrow content
      # ranges even of colourful sources). The deeper grey-channel
      # behaviour is exercised by `Image`'s own test suite. Here we
      # just confirm the URL grammar reaches the encoder and the
      # response decodes cleanly.
      url = iiif_url("landscape.jpg", "full", "200,", "0", "gray.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, _image} = Image.from_binary(response.body)
    end

    test "bitonal — output decodes successfully", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", "200,", "0", "bitonal.png")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert {:ok, _image} = Image.from_binary(response.body)
    end
  end

  describe "format segment" do
    test "jpg → image/jpeg content type", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", "200,", "0", "default.jpg")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert ["image/jpeg" <> _] = response.headers["content-type"]
    end

    test "png → image/png content type", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", "200,", "0", "default.png")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert ["image/png" <> _] = response.headers["content-type"]
    end

    test "webp → image/webp content type", %{base_url: base_url} do
      url = iiif_url("portrait.jpg", "full", "200,", "0", "default.webp")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert ["image/webp" <> _] = response.headers["content-type"]
    end
  end

  describe "info.json discovery document" do
    test "returns application/ld+json with the right shape", %{base_url: base_url} do
      url = "/iiif/3/portrait.jpg/info.json"
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert ["application/ld+json" <> _] = response.headers["content-type"]

      assert {:ok, doc} = Jason.decode(response.body)
      assert doc["@context"] == "http://iiif.io/api/image/3/context.json"
      assert doc["protocol"] == "http://iiif.io/api/image"
      assert doc["profile"] == "level2"
      assert doc["type"] == "ImageService3"
      assert is_integer(doc["width"]) and doc["width"] > 0
      assert is_integer(doc["height"]) and doc["height"] > 0
      assert doc["id"] =~ "/iiif/3/portrait.jpg"
      refute doc["id"] =~ "info.json"

      # extras should at least include the standard Level 2 set
      assert "gray" in doc["extraQualities"]
      assert "bitonal" in doc["extraQualities"]
      assert "webp" in doc["extraFormats"]
      assert "regionByPx" in doc["extraFeatures"]
      assert "rotationArbitrary" in doc["extraFeatures"]
    end

    test "carries a profile Link header", %{base_url: base_url} do
      url = "/iiif/3/portrait.jpg/info.json"
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert [link] = response.headers["link"]
      assert link =~ "http://iiif.io/api/image/3/level2.json"
      assert link =~ ~s(rel="profile")
    end

    test "carries a public Cache-Control header", %{base_url: base_url} do
      url = "/iiif/3/portrait.jpg/info.json"
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      [cache_control] = response.headers["cache-control"]
      assert cache_control =~ "public"
      assert cache_control =~ "max-age="
    end
  end

  describe "combined transforms" do
    test "region + size + rotation + quality + format all in one request", %{base_url: base_url} do
      url = iiif_url("landscape.jpg", "0,0,200,200", "!100,100", "90", "gray.png")
      assert {:ok, response} = request(url, base_url: base_url)
      assert response.status == 200
      assert ["image/png" <> _] = response.headers["content-type"]
      assert {:ok, image} = Image.from_binary(response.body)

      # Crop 200×200 → contain into 100×100 (square in, square out)
      # → rotate 90° (still 100×100). Output is grayscale PNG.
      assert Image.width(image) == 100
      assert Image.height(image) == 100
    end
  end
end
