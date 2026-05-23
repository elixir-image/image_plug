defmodule Image.Plug.Provider.Cloudinary.OptionsTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.Cloudinary.Options

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops
  alias Image.Plug.Provider.Cloudinary.Options

  describe "sizing" do
    test "w + h" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: 200, height: 100}]}} =
               Options.parse("w_200,h_100")
    end

    test "c_ values map to canonical fit atoms" do
      mapping = [
        {"scale", :squeeze},
        {"fit", :contain},
        {"limit", :scale_down},
        {"fill", :cover},
        {"crop", :crop},
        {"thumb", :cover},
        {"pad", :pad}
      ]

      for {wire, atom} <- mapping do
        assert {:ok, %Pipeline{ops: [%Ops.Resize{fit: ^atom}]}} =
                 Options.parse("w_100,c_#{wire}")
      end
    end

    test "g_xy_center with x_/y_ produces {:xy, x, y} gravity" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: {:xy, +0.25, +0.75}}]}} =
               Options.parse("w_100,c_fill,g_xy_center,x_0.25,y_0.75")
    end

    test "g_north maps to gravity :north" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: :north}]}} =
               Options.parse("w_100,c_fill,g_north")
    end

    test "g_face maps to :face" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: :face}]}} =
               Options.parse("w_100,c_fill,g_face")
    end

    test "dpr is capped at 3" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{dpr: 3}]}} = Options.parse("w_100,dpr_5")
    end
  end

  describe "format" do
    test "f_jpg/png/webp/avif" do
      mapping = [{"jpg", :jpeg}, {"png", :png}, {"webp", :webp}, {"avif", :avif}]

      for {wire, atom} <- mapping do
        assert {:ok, %Pipeline{output: %Ops.Format{type: ^atom}}} = Options.parse("f_#{wire}")
      end
    end

    test "f_auto sets type :auto" do
      assert {:ok, %Pipeline{output: %Ops.Format{type: :auto}}} = Options.parse("f_auto")
    end

    test "q_<int> in 1..100" do
      assert {:ok, %Pipeline{output: %Ops.Format{quality: 85}}} = Options.parse("q_85")
    end

    test "q_auto leaves the encoder default and sets compression :fast" do
      assert {:ok, %Pipeline{output: %Ops.Format{compression: :fast}}} = Options.parse("q_auto")

      assert {:ok, %Pipeline{output: %Ops.Format{compression: :fast}}} =
               Options.parse("q_auto:eco")
    end

    test "q out of range errors :invalid_option" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("q_150")
    end
  end

  describe "effects" do
    test "e_blur:300 maps to Blur sigma 3.0" do
      assert {:ok, %Pipeline{ops: [%Ops.Blur{sigma: +3.0}]}} = Options.parse("e_blur:300")
    end

    test "e_blur with no value defaults to 100 → sigma 1.0" do
      assert {:ok, %Pipeline{ops: [%Ops.Blur{sigma: +1.0}]}} = Options.parse("e_blur")
    end

    test "e_sharpen:50 maps to Sharpen sigma 5.0" do
      assert {:ok, %Pipeline{ops: [%Ops.Sharpen{sigma: +5.0}]}} = Options.parse("e_sharpen:50")
    end

    test "e_brightness/contrast/saturation/gamma adjustments" do
      assert {:ok,
              %Pipeline{
                ops: [
                  %Ops.Adjust{
                    brightness: +1.2,
                    contrast: +1.1,
                    saturation: +0.5,
                    gamma: +0.9
                  }
                ]
              }} =
               Options.parse("e_brightness:20,e_contrast:10,e_saturation:-50,e_gamma:-10")
    end

    test "e_grayscale sets adjust.saturation to 0" do
      assert {:ok, %Pipeline{ops: [%Ops.Adjust{saturation: +0.0}]}} =
               Options.parse("e_grayscale")
    end

    test "b_rgb:RRGGBB emits Background op with #-prefix" do
      assert {:ok, %Pipeline{ops: [%Ops.Background{color: "#ff0000"}]}} =
               Options.parse("b_rgb:ff0000")
    end

    test "e_replace_color:<to> emits ReplaceColor with :auto source" do
      assert {:ok, %Pipeline{ops: [%Ops.ReplaceColor{} = op]}} =
               Options.parse("e_replace_color:white")

      assert op.to == "white"
      assert op.from == :auto
      assert op.threshold == 50
    end

    test "e_replace_color:<to>:<tolerance>" do
      assert {:ok, %Pipeline{ops: [%Ops.ReplaceColor{to: "white", threshold: 30}]}} =
               Options.parse("e_replace_color:white:30")
    end

    test "e_replace_color:<to>:<tolerance>:<from> with hex inputs" do
      assert {:ok,
              %Pipeline{
                ops: [
                  %Ops.ReplaceColor{
                    to: "#ffffff",
                    from: "#ff0000",
                    threshold: 25
                  }
                ]
              }} = Options.parse("e_replace_color:ffffff:25:ff0000")
    end

    test "e_replace_color with rgb:RRGGBB source" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.ReplaceColor{from: "#abcdef"}]
              }} = Options.parse("e_replace_color:white:50:rgb:abcdef")
    end

    test "e_replace_color tolerance must be a non-negative integer" do
      assert {:error, %Error{tag: :invalid_option}} =
               Options.parse("e_replace_color:white:notanumber")
    end
  end

  describe "colorspace" do
    test "cs_srgb emits a Colorspace op" do
      assert {:ok, %Pipeline{ops: [%Ops.Colorspace{target: :srgb}]}} =
               Options.parse("cs_srgb")
    end

    test "cs_tinysrgb maps to :srgb (Cloudinary's tinification is a product layer, not a colorspace)" do
      assert {:ok, %Pipeline{ops: [%Ops.Colorspace{target: :srgb}]}} =
               Options.parse("cs_tinysrgb")
    end

    test "cs_cmyk emits a Colorspace{target: :cmyk}" do
      assert {:ok, %Pipeline{ops: [%Ops.Colorspace{target: :cmyk}]}} =
               Options.parse("cs_cmyk")
    end
  end

  describe "geometry" do
    test "a_<n> with n%90==0 emits Rotate" do
      assert {:ok, %Pipeline{ops: [%Ops.Rotate{angle: 90}]}} = Options.parse("a_90")
      assert {:ok, %Pipeline{ops: [%Ops.Rotate{angle: 180}]}} = Options.parse("a_180")
    end

    test "a_<n> with n%90!=0 errors" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("a_45")
    end

    test "bo_<W>px_solid_<color> emits a uniform Border" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.Border{color: "#000000", top: 5, right: 5, bottom: 5, left: 5}]
              }} = Options.parse("bo_5px_solid_000000")

      assert {:ok, %Pipeline{ops: [%Ops.Border{color: "#ff0000"}]}} =
               Options.parse("bo_3px_solid_rgb:ff0000")
    end

    test "fl_force_strip etc. are silently accepted" do
      assert {:ok, %Pipeline{ops: []}} = Options.parse("fl_force_strip")
      assert {:ok, %Pipeline{ops: []}} = Options.parse("fl_progressive")
    end
  end

  describe "overlays" do
    test "l_<public-id> emits a single-Layer Draw op" do
      assert {:ok, %Pipeline{ops: [%Ops.Draw{layers: [layer]}]}} =
               Options.parse("l_watermarks:logo.png")

      assert layer.source.kind == :path
      # `:` is replaced with `:` literally - we don't transform it.
      assert layer.source.ref =~ "watermarks"
    end
  end

  describe "unsupported / unknown" do
    test "e_vignette emits a Vignette op" do
      assert {:ok, %Pipeline{ops: [%Ops.Vignette{strength: 0.5}]}} =
               Options.parse("e_vignette")
    end

    test "e_vignette:30 emits a Vignette op with the parsed strength" do
      assert {:ok, %Pipeline{ops: [%Ops.Vignette{strength: 0.3}]}} =
               Options.parse("e_vignette:30")
    end

    test "e_improve emits an Enhance op" do
      assert {:ok, %Pipeline{ops: [%Ops.Enhance{}]}} = Options.parse("e_improve")
    end

    test "cs_<unsupported> returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("cs_adobergb")
    end

    test "t_<name> returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("t_my_named")
    end

    test "unknown key strict=true returns :unknown_option" do
      assert {:error, %Error{tag: :unknown_option}} = Options.parse("notarealkey_1")
    end

    test "unknown key strict=false ignored" do
      assert {:ok, %Pipeline{ops: []}} = Options.parse("notarealkey_1", strict?: false)
    end
  end

  describe "round-trip canonical ordering" do
    test "rotate -> resize -> background -> border -> adjust -> sharpen -> blur" do
      {:ok, pipeline} =
        Options.parse(
          "e_blur:200,e_sharpen:20,e_brightness:10,bo_2px_solid_fff,b_rgb:000,w_200,c_fill,a_90"
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
