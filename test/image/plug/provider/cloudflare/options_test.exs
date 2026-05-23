defmodule Image.Plug.Provider.Cloudflare.OptionsTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.Cloudflare.Options

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops
  alias Image.Plug.Provider.Cloudflare.Options

  describe "core resize keys" do
    test "width as integer" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: 200, height: nil}]}} =
               Options.parse("width=200")
    end

    test "width=auto" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: :auto}]}} = Options.parse("width=auto")
    end

    test "height as integer" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: nil, height: 300}]}} =
               Options.parse("height=300")
    end

    test "width and height combine into one Resize op" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: 200, height: 300}]}} =
               Options.parse("width=200,height=300")
    end

    test "fit accepts every documented value" do
      for {input, expected} <- [
            {"contain", :contain},
            {"cover", :cover},
            {"crop", :crop},
            {"pad", :pad},
            {"scale-down", :scale_down},
            {"squeeze", :squeeze}
          ] do
        assert {:ok, %Pipeline{ops: [%Ops.Resize{fit: ^expected}]}} =
                 Options.parse("width=200,fit=#{input}")
      end
    end

    test "fit with an invalid value errors :invalid_option" do
      assert {:error, %Error{tag: :invalid_option, details: %{key: "fit"}}} =
               Options.parse("width=200,fit=bogus")
    end

    test "rejects width=0" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("width=0")
    end

    test "rejects width=-5" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("width=-5")
    end

    test "rejects width=foo" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("width=foo")
    end
  end

  describe "format" do
    test "every documented format is accepted" do
      for {input, expected} <- [
            {"auto", :auto},
            {"avif", :avif},
            {"webp", :webp},
            {"jpeg", :jpeg},
            {"baseline-jpeg", :baseline_jpeg},
            {"png", :png},
            {"json", :json}
          ] do
        assert {:ok, %Pipeline{output: %Ops.Format{type: ^expected}}} =
                 Options.parse("format=#{input}")
      end
    end

    test "unknown format errors :invalid_option" do
      assert {:error, %Error{tag: :invalid_option, details: %{key: "format"}}} =
               Options.parse("format=bmp")
    end
  end

  describe "quality" do
    test "integer in range" do
      assert {:ok, %Pipeline{output: %Ops.Format{quality: 70}}} = Options.parse("quality=70")
    end

    test "named values" do
      for {input, expected} <- [
            {"high", 90},
            {"medium-high", 80},
            {"medium-low", 65},
            {"low", 50}
          ] do
        assert {:ok, %Pipeline{output: %Ops.Format{quality: ^expected}}} =
                 Options.parse("quality=#{input}")
      end
    end

    test "out-of-range errors :invalid_option" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("quality=0")
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("quality=101")
    end
  end

  describe "aliases" do
    test "single-letter aliases normalise to the canonical key" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.Resize{width: 100, height: 200, fit: :cover}],
                output: %Ops.Format{type: :webp, quality: 70}
              }} =
               Options.parse("w=100,h=200,fit=cover,q=70,f=webp")
    end
  end

  describe "unknown keys" do
    test "strict? defaults to true" do
      assert {:error, %Error{tag: :unknown_option, details: %{key: "wat"}}} =
               Options.parse("wat=1")
    end

    test "strict?: false ignores unknown keys" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: 200}]}} =
               Options.parse("wat=1,width=200", strict?: false)
    end
  end

  describe "empty input" do
    test "empty string yields an empty pipeline" do
      assert {:ok, %Pipeline{ops: []}} = Options.parse("")
    end
  end

  describe "gravity" do
    test "named values map to canonical atoms" do
      for {input, expected} <- [
            {"auto", :auto},
            {"face", :face},
            {"center", :center},
            {"centre", :center},
            {"left", :west},
            {"right", :east},
            {"top", :north},
            {"bottom", :south},
            {"north", :north},
            {"northeast", :north_east}
          ] do
        assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: ^expected}]}} =
                 Options.parse("width=100,gravity=#{input}")
      end
    end

    test "XxY normalised coordinates" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: {:xy, +0.25, +0.75}}]}} =
               Options.parse("width=100,gravity=0.25x0.75")
    end

    test "out-of-range XxY errors :invalid_option" do
      assert {:error, %Error{tag: :invalid_option}} =
               Options.parse("width=100,gravity=2.0x0.5")
    end
  end

  describe "dpr" do
    test "sets resize.dpr and output.dpr" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{dpr: 2}], output: %Ops.Format{dpr: 2}}} =
               Options.parse("width=100,dpr=2")
    end
  end

  describe "rotate" do
    test "accepts multiples of 90" do
      for angle <- [90, 180, 270, 360] do
        assert {:ok, %Pipeline{ops: [%Ops.Rotate{angle: ^angle}]}} =
                 Options.parse("rotate=#{angle}")
      end
    end

    test "rejects non-multiples of 90" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("rotate=45")
    end
  end

  describe "flip" do
    test "every documented value" do
      for {input, expected} <- [
            {"h", :horizontal},
            {"v", :vertical},
            {"hv", :both}
          ] do
        assert {:ok, %Pipeline{ops: [%Ops.Flip{direction: ^expected}]}} =
                 Options.parse("flip=#{input}")
      end
    end
  end

  describe "trim" do
    test "trim=border" do
      assert {:ok, %Pipeline{ops: [%Ops.Trim{mode: :border}]}} = Options.parse("trim=border")
    end

    test "trim=top;right;bottom;left" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.Trim{mode: :explicit, top: 5, right: 6, bottom: 7, left: 8}]
              }} = Options.parse("trim=5;6;7;8")
    end

    test "trim with too few segments errors" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("trim=5;6")
    end
  end

  describe "border" do
    test "uniform width form" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.Border{color: "#ff0000", top: 4, right: 4, bottom: 4, left: 4}]
              }} = Options.parse("border=color=#ff0000;width=4")
    end

    test "per-side form" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.Border{color: "#000000", top: 1, right: 2, bottom: 3, left: 4}]
              }} = Options.parse("border=top=1;right=2;bottom=3;left=4")
    end
  end

  describe "effects" do
    test "background appends a Background op" do
      assert {:ok, %Pipeline{ops: [%Ops.Background{color: "#fff"}]}} =
               Options.parse("background=#fff")
    end

    test "blur N maps to a libvips sigma" do
      assert {:ok, %Pipeline{ops: [%Ops.Blur{sigma: sigma}]}} = Options.parse("blur=20")
      assert sigma == 10.0
    end

    test "sharpen N maps to a libvips sigma" do
      assert {:ok, %Pipeline{ops: [%Ops.Sharpen{sigma: sigma}]}} = Options.parse("sharpen=2")
      assert sigma == 2.0
    end

    test "brightness/contrast/gamma/saturation fold into one Adjust op" do
      assert {:ok,
              %Pipeline{
                ops: [
                  %Ops.Adjust{
                    brightness: +1.2,
                    contrast: +0.9,
                    gamma: +1.1,
                    saturation: +0.5
                  }
                ]
              }} =
               Options.parse("brightness=1.2,contrast=0.9,gamma=1.1,saturation=0.5")
    end
  end

  describe "metadata / anim / compression" do
    test "metadata sets output.metadata" do
      for {input, expected} <- [
            {"copyright", :copyright},
            {"keep", :keep},
            {"none", :none}
          ] do
        assert {:ok, %Pipeline{output: %Ops.Format{metadata: ^expected}}} =
                 Options.parse("metadata=#{input}")
      end
    end

    test "anim=false sets output.anim?" do
      assert {:ok, %Pipeline{output: %Ops.Format{anim?: false}}} = Options.parse("anim=false")
    end

    test "compression=fast sets output.compression" do
      assert {:ok, %Pipeline{output: %Ops.Format{compression: :fast}}} =
               Options.parse("compression=fast")
    end
  end

  describe "onerror" do
    test "redirect maps to :fallback_to_source" do
      assert {:ok, %Pipeline{on_error: :fallback_to_source}} = Options.parse("onerror=redirect")
    end
  end

  describe "draw= sub-grammar" do
    test "single layer with url() only" do
      assert {:ok, %Pipeline{ops: [%Ops.Draw{layers: [layer]}]}} =
               Options.parse("draw=url(https://example.com/wm.png)")

      assert layer.source.kind == :url
      assert layer.source.ref == "https://example.com/wm.png"
      assert layer.opacity == 1.0
      assert layer.position == nil
    end

    test "with size and position fields" do
      assert {:ok,
              %Pipeline{
                ops: [
                  %Ops.Draw{
                    layers: [
                      %Ops.Draw.Layer{
                        width: 100,
                        height: 100,
                        opacity: +0.5,
                        position: {:offset, [top: nil, right: 5, bottom: 5, left: nil]}
                      }
                    ]
                  }
                ]
              }} =
               Options.parse(
                 "draw=url(https://example.com/wm.png);width=100;height=100;opacity=0.5;right=5;bottom=5"
               )
    end

    test "multiple draw= entries become multiple layers in order" do
      {:ok, %Pipeline{ops: [%Ops.Draw{layers: layers}]}} =
        Options.parse(
          "draw=url(https://example.com/a.png);width=50," <>
            "draw=url(https://example.com/b.png);width=75"
        )

      assert length(layers) == 2
      assert Enum.at(layers, 0).source.ref == "https://example.com/a.png"
      assert Enum.at(layers, 1).source.ref == "https://example.com/b.png"
    end

    test "rejects setting both top and bottom" do
      assert {:error, %Error{tag: :invalid_option}} =
               Options.parse("draw=url(https://example.com/wm.png);top=5;bottom=5")
    end

    test "rejects setting both left and right" do
      assert {:error, %Error{tag: :invalid_option}} =
               Options.parse("draw=url(https://example.com/wm.png);left=5;right=5")
    end

    test "rejects opacity outside 0..1" do
      assert {:error, %Error{tag: :invalid_option}} =
               Options.parse("draw=url(https://example.com/wm.png);opacity=2.0")
    end

    test "rejects rotate that is not 0/90/180/270" do
      assert {:error, %Error{tag: :invalid_option}} =
               Options.parse("draw=url(https://example.com/wm.png);rotate=45")
    end

    test "rejects missing url(...)" do
      assert {:error, %Error{tag: :invalid_option}} =
               Options.parse("draw=width=100")
    end
  end

  describe "canonical ordering" do
    test "rotate -> trim -> flip -> resize -> background -> border -> adjust -> sharpen -> blur" do
      {:ok, pipeline} =
        Options.parse(
          "blur=10,sharpen=1,brightness=1.1,border=color=#fff;width=2," <>
            "background=#000,width=200,fit=cover,flip=h,trim=border,rotate=90"
        )

      kinds = Enum.map(pipeline.ops, & &1.__struct__)

      assert kinds == [
               Ops.Rotate,
               Ops.Trim,
               Ops.Flip,
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
