defmodule Image.Plug.Provider.ImageKit.OptionsTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.ImageKit.Options

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops
  alias Image.Plug.Provider.ImageKit.Options

  describe "sizing" do
    test "w + h" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: 200, height: 100}]}} =
               Options.parse("w-200,h-100")
    end

    test "c-/cm- values map to canonical fit atoms" do
      mapping = [
        {"maintain_ratio", :contain},
        {"force", :squeeze},
        {"at_least", :scale_down},
        {"at_max", :scale_down},
        {"extract", :crop},
        {"pad_extract", :pad},
        {"pad_resize", :pad}
      ]

      for {wire, atom} <- mapping do
        assert {:ok, %Pipeline{ops: [%Ops.Resize{fit: ^atom}]}} =
                 Options.parse("w-100,c-#{wire}")

        assert {:ok, %Pipeline{ops: [%Ops.Resize{fit: ^atom}]}} =
                 Options.parse("w-100,cm-#{wire}")
      end
    end

    test "fo-custom + x-/y- produces {:xy, x, y} gravity" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: {:xy, +0.25, +0.75}}]}} =
               Options.parse("w-100,c-extract,fo-custom,x-0.25,y-0.75")
    end

    test "fo-top maps to gravity :north" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: :north}]}} =
               Options.parse("w-100,c-extract,fo-top")
    end

    test "fo-face maps to :face" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: :face}]}} =
               Options.parse("w-100,c-extract,fo-face")
    end

    test "dpr is capped at 3" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{dpr: 3}]}} = Options.parse("w-100,dpr-5")
    end
  end

  describe "format" do
    test "f-jpg/png/webp/avif" do
      mapping = [{"jpg", :jpeg}, {"png", :png}, {"webp", :webp}, {"avif", :avif}]

      for {wire, atom} <- mapping do
        assert {:ok, %Pipeline{output: %Ops.Format{type: ^atom}}} = Options.parse("f-#{wire}")
      end
    end

    test "f-auto sets type :auto" do
      assert {:ok, %Pipeline{output: %Ops.Format{type: :auto}}} = Options.parse("f-auto")
    end

    test "q-<int> in 1..100" do
      assert {:ok, %Pipeline{output: %Ops.Format{quality: 85}}} = Options.parse("q-85")
    end

    test "q out of range errors :invalid_option" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("q-150")
    end
  end

  describe "effects" do
    test "e-blur-300 maps to Blur sigma 3.0" do
      assert {:ok, %Pipeline{ops: [%Ops.Blur{sigma: +3.0}]}} = Options.parse("e-blur-300")
    end

    test "e-sharpen-50 maps to Sharpen sigma 5.0" do
      assert {:ok, %Pipeline{ops: [%Ops.Sharpen{sigma: +5.0}]}} = Options.parse("e-sharpen-50")
    end

    test "e-grayscale sets adjust.saturation to 0" do
      assert {:ok, %Pipeline{ops: [%Ops.Adjust{saturation: +0.0}]}} =
               Options.parse("e-grayscale")
    end

    test "e-contrast bumps Adjust.contrast to 1.1" do
      assert {:ok, %Pipeline{ops: [%Ops.Adjust{contrast: +1.1}]}} =
               Options.parse("e-contrast")
    end

    test "e-usm-<r>-<sigma>-<amt>-<thr> maps to Sharpen by sigma" do
      assert {:ok, %Pipeline{ops: [%Ops.Sharpen{sigma: +5.0}]}} =
               Options.parse("e-usm-2-50-1-0")
    end

    test "bg adds # if missing and emits Background op" do
      assert {:ok, %Pipeline{ops: [%Ops.Background{color: "#ff0000"}]}} =
               Options.parse("bg-ff0000")
    end
  end

  describe "geometry" do
    test "rt-<n> with n%90==0 emits Rotate" do
      assert {:ok, %Pipeline{ops: [%Ops.Rotate{angle: 90}]}} = Options.parse("rt-90")
      assert {:ok, %Pipeline{ops: [%Ops.Rotate{angle: 180}]}} = Options.parse("rt-180")
    end

    test "rt-<n> with n%90!=0 errors" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("rt-45")
    end

    test "b-<W>_<color> emits a uniform Border" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.Border{color: "#000000", top: 5, right: 5, bottom: 5, left: 5}]
              }} = Options.parse("b-5_000000")
    end
  end

  describe "overlays" do
    test "oi-<path> emits a single-Layer Draw op" do
      assert {:ok, %Pipeline{ops: [%Ops.Draw{layers: [layer]}]}} =
               Options.parse("oi-watermarks/logo.png")

      assert layer.source.kind == :path
      assert layer.source.ref =~ "watermarks"
    end
  end

  describe "unsupported / unknown" do
    test "e-shadow returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("e-shadow")
    end

    test "lo returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("lo-true")
    end

    test "t- (named transform) returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("t-my_named")
    end

    test "unknown key strict=true returns :unknown_option" do
      assert {:error, %Error{tag: :unknown_option}} = Options.parse("notarealkey-1")
    end

    test "unknown key strict=false ignored" do
      assert {:ok, %Pipeline{ops: []}} = Options.parse("notarealkey-1", strict?: false)
    end
  end

  describe "round-trip canonical ordering" do
    test "rotate -> resize -> background -> border -> adjust -> sharpen -> blur" do
      {:ok, pipeline} =
        Options.parse(
          "e-blur-200,e-sharpen-20,e-contrast,b-2_fff,bg-000,w-200,c-extract,rt-90"
        )

      kinds = Enum.map(pipeline.ops, & &1.__struct__)

      assert kinds == [
               Ops.Rotate,
               Ops.Resize,
               Ops.Background,
               Ops.Border,
               Ops.Adjust,
               Ops.Sharpen,
               Ops.Blur
             ]
    end
  end
end
