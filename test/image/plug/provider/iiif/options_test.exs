defmodule Image.Plug.Provider.IIIF.OptionsTest do
  @moduledoc """
  Tests for `Image.Plug.Provider.IIIF.Options.parse/2` — the
  segment-decoder. Walks through every accepted form for region /
  size / rotation / quality / format and confirms each lands in
  the right IR op.
  """

  use ExUnit.Case, async: true

  alias Image.Plug.Provider.IIIF.Options
  alias Image.Plug.Pipeline
  alias Image.Plug.Pipeline.Ops

  defp parse(region, size, rotation, qf) do
    Options.parse({region, size, rotation, qf})
  end

  describe "region" do
    test "full → no Crop op" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "0", "default.jpg")
      refute Enum.find(ops, &match?(%Ops.Crop{}, &1))
    end

    test "x,y,w,h → pixel Crop" do
      assert {:ok, %Pipeline{ops: ops}} = parse("100,50,400,300", "max", "0", "default.jpg")

      assert %Ops.Crop{x: 100, y: 50, width: 400, height: 300, units: :pixels} =
               Enum.find(ops, &match?(%Ops.Crop{}, &1))
    end

    test "pct:x,y,w,h → percent Crop" do
      assert {:ok, %Pipeline{ops: ops}} = parse("pct:25,25,50,50", "max", "0", "default.jpg")

      assert %Ops.Crop{units: :percent, x: 25.0, y: 25.0, width: 50.0, height: 50.0} =
               Enum.find(ops, &match?(%Ops.Crop{}, &1))
    end

    test "square → percent Crop covering whole image (lossy fallback)" do
      assert {:ok, %Pipeline{ops: ops}} = parse("square", "max", "0", "default.jpg")
      assert %Ops.Crop{units: :percent, width: 100, height: 100} = Enum.find(ops, &match?(%Ops.Crop{}, &1))
    end

    test "garbage region → malformed_url" do
      assert {:error, %{tag: :malformed_url}} = parse("not,a,region", "max", "0", "default.jpg")
    end
  end

  describe "size" do
    test "max → Resize{upscale?: false}" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "0", "default.jpg")
      assert %Ops.Resize{upscale?: false, width: nil, height: nil} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "^max → Resize{upscale?: true}" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "^max", "0", "default.jpg")
      assert %Ops.Resize{upscale?: true} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "w, → width-only Resize" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "600,", "0", "default.jpg")
      assert %Ops.Resize{width: 600, height: nil, upscale?: false} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test ",h → height-only Resize" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", ",400", "0", "default.jpg")
      assert %Ops.Resize{width: nil, height: 400} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "w,h → squeeze fit" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "600,400", "0", "default.jpg")
      assert %Ops.Resize{width: 600, height: 400, fit: :squeeze} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "!w,h → contain fit" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "!600,400", "0", "default.jpg")
      assert %Ops.Resize{width: 600, height: 400, fit: :contain} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "^!w,h → contain fit + upscale" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "^!600,400", "0", "default.jpg")
      assert %Ops.Resize{width: 600, height: 400, fit: :contain, upscale?: true} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "pct:N → size_pct" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "pct:50", "0", "default.jpg")
      assert %Ops.Resize{size_pct: 50.0, upscale?: false, width: nil, height: nil} = Enum.find(ops, &match?(%Ops.Resize{}, &1))
    end

    test "garbage size → malformed_url" do
      assert {:error, %{tag: :malformed_url}} = parse("full", "junk", "0", "default.jpg")
    end
  end

  describe "rotation" do
    test "0 → no Rotate op" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "0", "default.jpg")
      refute Enum.find(ops, &match?(%Ops.Rotate{}, &1))
    end

    test "90 → integer Rotate" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "90", "default.jpg")
      assert %Ops.Rotate{angle: 90} = Enum.find(ops, &match?(%Ops.Rotate{}, &1))
    end

    test "45.5 → float Rotate" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "45.5", "default.jpg")
      assert %Ops.Rotate{angle: 45.5} = Enum.find(ops, &match?(%Ops.Rotate{}, &1))
    end

    test "!90 (mirror-then-rotate) — angle parsed; mirror dropped" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "!90", "default.jpg")
      assert %Ops.Rotate{angle: 90} = Enum.find(ops, &match?(%Ops.Rotate{}, &1))
    end

    test "out-of-range angle → malformed_url" do
      assert {:error, %{tag: :malformed_url}} = parse("full", "max", "999", "default.jpg")
    end
  end

  describe "quality" do
    test "default → no quality op" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "0", "default.jpg")
      refute Enum.find(ops, &match?(%Ops.Adjust{}, &1))
      refute Enum.find(ops, &match?(%Ops.Posterize{}, &1))
    end

    test "color → no quality op (synonym of default)" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "0", "color.jpg")
      refute Enum.find(ops, &match?(%Ops.Adjust{}, &1))
    end

    test "gray → Adjust{saturation: 0.0}" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "0", "gray.jpg")
      assert %Ops.Adjust{saturation: s} = Enum.find(ops, &match?(%Ops.Adjust{}, &1))
      assert s == 0.0
    end

    test "bitonal → Posterize{levels: 2}" do
      assert {:ok, %Pipeline{ops: ops}} = parse("full", "max", "0", "bitonal.png")
      assert %Ops.Posterize{levels: 2} = Enum.find(ops, &match?(%Ops.Posterize{}, &1))
    end
  end

  describe "format" do
    test ".jpg → :jpeg" do
      assert {:ok, %Pipeline{output: out}} = parse("full", "max", "0", "default.jpg")
      assert out.type == :jpeg
    end

    test ".png → :png" do
      assert {:ok, %Pipeline{output: out}} = parse("full", "max", "0", "default.png")
      assert out.type == :png
    end

    test ".webp → :webp" do
      assert {:ok, %Pipeline{output: out}} = parse("full", "max", "0", "default.webp")
      assert out.type == :webp
    end

    test ".tif → :tiff" do
      assert {:ok, %Pipeline{output: out}} = parse("full", "max", "0", "default.tif")
      assert out.type == :tiff
    end

    test ".jp2 → :jp2" do
      assert {:ok, %Pipeline{output: out}} = parse("full", "max", "0", "default.jp2")
      assert out.type == :jp2
    end

    test ".bmp (unsupported) → malformed_url" do
      assert {:error, %{tag: :malformed_url}} = parse("full", "max", "0", "default.bmp")
    end
  end
end
