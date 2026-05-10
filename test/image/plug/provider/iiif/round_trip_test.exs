defmodule Image.Plug.Provider.IIIF.RoundTripTest do
  @moduledoc """
  Round-trip property tests for the IIIF Image API 3.0 parser.

  We hand-construct URL segment strings that match the spec, then
  feed them through `Image.Plug.Provider.IIIF.URL.parse/2` +
  `Image.Plug.Provider.IIIF.Options.parse/2` and assert the resulting
  Pipeline carries the operations the strings described.

  The symmetric image_components → image_plug round-trip
  (project a Pipeline to a URL via `Image.Components.URL.iiif/2`,
  parse it back, assert equality) lives in `image_components`'s
  test suite; replicating it here would create a circular test-dep.

  Tagged `:iiif_round_trip`; included in the default suite.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Image.Plug.Pipeline
  alias Image.Plug.Pipeline.Ops
  alias Image.Plug.Provider.IIIF.{Options, URL}

  @moduletag :iiif_round_trip

  describe "URL → Options round-trip via the full provider pipeline" do
    test "no transforms" do
      assert {:ok, %Pipeline{} = parsed} = parse_iiif_url(["iiif", "3", "x.jpg", "full", "max", "0", "default.jpg"])
      assert parsed.output.type == :jpeg
    end

    test "width-only resize" do
      assert {:ok, %Pipeline{ops: ops}} = parse_iiif_url(["iiif", "3", "x.jpg", "full", "600,", "0", "default.jpg"])
      assert %Ops.Resize{width: 600, upscale?: false} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "pixel crop" do
      url = ["iiif", "3", "x.jpg", "100,50,400,300", "max", "0", "default.jpg"]
      assert {:ok, %Pipeline{ops: ops}} = parse_iiif_url(url)
      assert %Ops.Crop{x: 100, y: 50, width: 400, height: 300, units: :pixels} = Enum.find(ops, &match?(%Ops.Crop{}, &1))
    end

    test "all five segments combined" do
      url = ["iiif", "3", "x.jpg", "pct:25,25,50,50", "^!600,400", "45", "gray.png"]
      assert {:ok, %Pipeline{ops: ops, output: out}} = parse_iiif_url(url)

      assert %Ops.Crop{units: :percent, x: 25.0, y: 25.0} = Enum.find(ops, &match?(%Ops.Crop{}, &1))
      assert %Ops.Resize{width: 600, height: 400, fit: :contain, upscale?: true} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
      assert %Ops.Rotate{angle: 45} = Enum.find(ops, &match?(%Ops.Rotate{}, &1))
      assert %Ops.Adjust{saturation: 0.0} = Enum.find(ops, &match?(%Ops.Adjust{}, &1))
      assert out.type == :png
    end
  end

  describe "properties — every URL parses to a Pipeline" do
    property "any well-formed size segment yields an :ok parse" do
      check all width <- integer(50..2000),
                upscale_prefix <- member_of(["", "^"]) do
        url = ["iiif", "3", "x.jpg", "full", "#{upscale_prefix}#{width},", "0", "default.jpg"]
        assert {:ok, %Pipeline{ops: ops}} = parse_iiif_url(url)
        resize = Enum.find(ops, &match?(%Ops.Resize{}, &1))
        assert resize.width == width
        assert resize.upscale? == (upscale_prefix == "^")
      end
    end

    property "any rotation 0..360 yields an :ok parse" do
      check all angle <- integer(0..360) do
        url = ["iiif", "3", "x.jpg", "full", "max", Integer.to_string(angle), "default.jpg"]
        assert {:ok, %Pipeline{ops: ops}} = parse_iiif_url(url)

        if angle == 0 do
          refute Enum.find(ops, &match?(%Ops.Rotate{}, &1))
        else
          assert %Ops.Rotate{angle: ^angle} = Enum.find(ops, &match?(%Ops.Rotate{}, &1))
        end
      end
    end

    property "all four IIIF qualities parse cleanly" do
      check all quality <- member_of(["default", "color", "gray", "bitonal"]),
                format <- member_of(["jpg", "png", "webp"]) do
        url = ["iiif", "3", "x.jpg", "full", "max", "0", "#{quality}.#{format}"]
        assert {:ok, %Pipeline{ops: ops}} = parse_iiif_url(url)

        case quality do
          "gray" ->
            assert Enum.find(ops, &match?(%Ops.Adjust{saturation: s} when s == 0.0, &1))

          "bitonal" ->
            assert Enum.find(ops, &match?(%Ops.Posterize{levels: 2}, &1))

          _ ->
            refute Enum.find(ops, &match?(%Ops.Adjust{}, &1))
            refute Enum.find(ops, &match?(%Ops.Posterize{}, &1))
        end
      end
    end
  end

  # Run a path_info through both URL.parse/2 and Options.parse/2,
  # mimicking what `Image.Plug.Provider.IIIF.parse/2` does for an
  # image-kind request.
  defp parse_iiif_url(path_info) do
    conn = %Plug.Conn{path_info: path_info}

    with {:ok, %{kind: :image, options_segments: segments}} <- URL.parse(conn, []) do
      Options.parse(segments)
    end
  end
end
