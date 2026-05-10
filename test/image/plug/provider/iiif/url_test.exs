defmodule Image.Plug.Provider.IIIF.URLTest do
  @moduledoc """
  Tests for `Image.Plug.Provider.IIIF.URL.parse/2` — the URL-shape
  recogniser. Covers prefix stripping (mount + endpoint), the
  `info.json` discovery form, the standard image-request form,
  identifier round-tripping, and rejection of malformed URLs.
  """

  use ExUnit.Case, async: true

  alias Image.Plug.Provider.IIIF.URL

  doctest URL

  defp conn(path_segments) do
    %Plug.Conn{path_info: path_segments}
  end

  describe "image URL form" do
    test "with default endpoint /iiif/3" do
      c = conn(["iiif", "3", "cat.jpg", "full", "max", "0", "default.jpg"])
      assert {:ok, %{kind: :image} = parsed} = URL.parse(c, [])
      assert parsed.options_segments == {"full", "max", "0", "default.jpg"}
      assert parsed.source.kind == :path
      assert parsed.source.ref == "/cat.jpg"
    end

    test "with custom endpoint" do
      c = conn(["image", "V0007727.jpg", "full", "200,", "0", "default.jpg"])
      assert {:ok, parsed} = URL.parse(c, endpoint: "image")
      assert parsed.kind == :image
      assert parsed.source.ref == "/V0007727.jpg"
      assert parsed.options_segments == {"full", "200,", "0", "default.jpg"}
    end

    test "empty endpoint → identifier directly under mount" do
      c = conn(["cat.jpg", "full", "max", "0", "default.jpg"])
      assert {:ok, parsed} = URL.parse(c, endpoint: "")
      assert parsed.kind == :image
      assert parsed.source.ref == "/cat.jpg"
    end

    test "URL-encoded identifier with embedded slashes" do
      c = conn(["iiif", "3", "sub%2Fcat.jpg", "full", "max", "0", "default.jpg"])
      assert {:ok, parsed} = URL.parse(c, [])
      assert parsed.source.ref == "/sub/cat.jpg"
    end

    test "URL-encoded identifier with spaces" do
      c = conn(["iiif", "3", "sub%20dir%2Fcat.jpg", "full", "max", "0", "default.jpg"])
      assert {:ok, parsed} = URL.parse(c, [])
      assert parsed.source.ref == "/sub dir/cat.jpg"
    end
  end

  describe "info.json URL form" do
    test "with default endpoint" do
      c = conn(["iiif", "3", "cat.jpg", "info.json"])
      assert {:ok, %{kind: :info_json} = parsed} = URL.parse(c, [])
      assert parsed.source.ref == "/cat.jpg"
      refute Map.has_key?(parsed, :options_segments)
    end

    test "with custom endpoint" do
      c = conn(["image", "V0007727.jpg", "info.json"])
      assert {:ok, parsed} = URL.parse(c, endpoint: "image")
      assert parsed.kind == :info_json
    end
  end

  describe "mount prefix stripping" do
    test "single-segment mount" do
      c = conn(["app", "iiif", "3", "cat.jpg", "full", "max", "0", "default.jpg"])
      assert {:ok, parsed} = URL.parse(c, mount: "/app")
      assert parsed.kind == :image
    end

    test "multi-segment mount" do
      c = conn(["a", "b", "iiif", "3", "cat.jpg", "info.json"])
      assert {:ok, parsed} = URL.parse(c, mount: "/a/b")
      assert parsed.kind == :info_json
    end

    test "mount mismatch is reported as malformed_url" do
      c = conn(["other", "iiif", "3", "cat.jpg", "info.json"])
      assert {:error, %Image.Plug.Error{tag: :malformed_url}} = URL.parse(c, mount: "/app")
    end

    test "endpoint mismatch is reported as malformed_url" do
      c = conn(["iiif", "2", "cat.jpg", "info.json"])
      assert {:error, %Image.Plug.Error{tag: :malformed_url}} = URL.parse(c, [])
    end
  end

  describe "rejection" do
    test "bare identifier — spec says redirect to info.json (TODO)" do
      c = conn(["iiif", "3", "cat.jpg"])
      assert {:error, %{tag: :malformed_url}} = URL.parse(c, [])
    end

    test "wrong segment count — too few" do
      c = conn(["iiif", "3", "cat.jpg", "full", "max"])
      assert {:error, %{tag: :malformed_url}} = URL.parse(c, [])
    end

    test "wrong segment count — too many" do
      c = conn(["iiif", "3", "cat.jpg", "full", "max", "0", "default.jpg", "extra"])
      assert {:error, %{tag: :malformed_url}} = URL.parse(c, [])
    end
  end
end
