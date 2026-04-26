defmodule Image.Plug.Provider.Imgix.OptionsTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.Imgix.Options

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Ops
  alias Image.Plug.Provider.Imgix.Options

  describe "sizing" do
    test "w + h" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{width: 200, height: 100}]}} =
               Options.parse("w=200&h=100")
    end

    test "fit values map to canonical IR atoms" do
      mapping = [
        {"clip", :contain},
        {"clamp", :contain},
        {"crop", :cover},
        {"facearea", :cover},
        {"fill", :pad},
        {"max", :scale_down},
        {"scale", :squeeze}
      ]

      for {wire, atom} <- mapping do
        assert {:ok, %Pipeline{ops: [%Ops.Resize{fit: ^atom}]}} =
                 Options.parse("w=100&fit=#{wire}")
      end
    end

    test "crop=focalpoint with fp-x/fp-y produces {:xy, x, y} gravity" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: {:xy, +0.25, +0.75}}]}} =
               Options.parse("w=100&fit=crop&crop=focalpoint&fp-x=0.25&fp-y=0.75")
    end

    test "crop=top maps to gravity :north" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{gravity: :north}]}} =
               Options.parse("w=100&fit=crop&crop=top")
    end

    test "dpr is capped at 3" do
      assert {:ok, %Pipeline{ops: [%Ops.Resize{dpr: 3}]}} = Options.parse("w=100&dpr=5")
    end
  end

  describe "format" do
    test "fm=jpg/png/webp/avif" do
      mapping = [{"jpg", :jpeg}, {"png", :png}, {"webp", :webp}, {"avif", :avif}]

      for {wire, atom} <- mapping do
        assert {:ok, %Pipeline{output: %Ops.Format{type: ^atom}}} = Options.parse("fm=#{wire}")
      end
    end

    test "auto=format sets type to :auto" do
      assert {:ok, %Pipeline{output: %Ops.Format{type: :auto}}} = Options.parse("auto=format")
    end

    test "auto=format,compress sets type and compression" do
      assert {:ok, %Pipeline{output: %Ops.Format{type: :auto, compression: :fast}}} =
               Options.parse("auto=format,compress")
    end

    test "auto=enhance returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("auto=enhance")
    end

    test "q in 1..100" do
      assert {:ok, %Pipeline{output: %Ops.Format{quality: 85}}} = Options.parse("q=85")
    end

    test "q out of range errors :invalid_option" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("q=150")
    end
  end

  describe "effects" do
    test "blur scaled by /100" do
      assert {:ok, %Pipeline{ops: [%Ops.Blur{sigma: +5.0}]}} = Options.parse("blur=500")
    end

    test "sharp scaled by /10" do
      assert {:ok, %Pipeline{ops: [%Ops.Sharpen{sigma: +5.0}]}} = Options.parse("sharp=50")
    end

    test "bri/con/sat/gam map to 1.0 + N/100 multipliers" do
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
              }} = Options.parse("bri=20&con=10&sat=-50&gam=-10")
    end

    test "bri out of -100..100 errors" do
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("bri=200")
    end

    test "bg adds # if missing and emits Background op" do
      assert {:ok, %Pipeline{ops: [%Ops.Background{color: "#ff0000"}]}} = Options.parse("bg=ff0000")
      assert {:ok, %Pipeline{ops: [%Ops.Background{color: "#fff"}]}} = Options.parse("bg=%23fff")
    end
  end

  describe "geometry" do
    test "flip" do
      assert {:ok, %Pipeline{ops: [%Ops.Flip{direction: :horizontal}]}} = Options.parse("flip=h")
      assert {:ok, %Pipeline{ops: [%Ops.Flip{direction: :both}]}} = Options.parse("flip=hv")
    end

    test "rot accepts multiples of 90" do
      assert {:ok, %Pipeline{ops: [%Ops.Rotate{angle: 90}]}} = Options.parse("rot=90")
      assert {:error, %Error{tag: :invalid_option}} = Options.parse("rot=45")
    end

    test "trim=auto" do
      assert {:ok, %Pipeline{ops: [%Ops.Trim{mode: :border}]}} = Options.parse("trim=auto")
    end

    test "border=W,#hex" do
      assert {:ok,
              %Pipeline{
                ops: [%Ops.Border{color: "#000000", top: 5, right: 5, bottom: 5, left: 5}]
              }} = Options.parse("border=5,000000")
    end
  end

  describe "overlays" do
    test "mark=<url> emits a Draw op with one Layer" do
      assert {:ok, %Pipeline{ops: [%Ops.Draw{layers: [layer]}]}} =
               Options.parse("mark=https%3A%2F%2Fexample.com%2Fwm.png")

      assert layer.source.kind == :url
      assert layer.source.ref == "https://example.com/wm.png"
    end
  end

  describe "colorspace" do
    test "cs=srgb emits a Colorspace op" do
      assert {:ok, %Pipeline{ops: [%Ops.Colorspace{target: :srgb}]}} =
               Options.parse("cs=srgb")
    end

    test "cs=cmyk emits a Colorspace op" do
      assert {:ok, %Pipeline{ops: [%Ops.Colorspace{target: :cmyk}]}} =
               Options.parse("cs=cmyk")
    end

    test "cs=strip is treated as a sRGB conversion (drops embedded ICC profiles)" do
      assert {:ok, %Pipeline{ops: [%Ops.Colorspace{target: :srgb}]}} =
               Options.parse("cs=strip")
    end

    test "monochrome=<hex> emits a Colorspace{target: :bw} op (hex tint not yet honoured)" do
      assert {:ok, %Pipeline{ops: [%Ops.Colorspace{target: :bw}]}} =
               Options.parse("monochrome=ff0000")
    end
  end

  describe "unsupported / unknown" do
    test "sepia returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("sepia=80")
    end

    test "cs=adobergb1998 returns :unsupported_option (Adobe RGB needs ICC support)" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("cs=adobergb1998")
    end

    test "or returns :unsupported_option" do
      assert {:error, %Error{tag: :unsupported_option}} = Options.parse("or=6")
    end

    test "unknown key strict=true returns :unknown_option" do
      assert {:error, %Error{tag: :unknown_option}} = Options.parse("notarealkey=1")
    end

    test "unknown key strict=false ignored" do
      assert {:ok, %Pipeline{ops: []}} = Options.parse("notarealkey=1", strict?: false)
    end

    test "ixlib / ixid client identification keys are silently ignored" do
      assert {:ok, %Pipeline{ops: []}} = Options.parse("ixlib=elixir-1.0&ixid=abc")
    end
  end

  describe "round-trip-friendly canonical ordering" do
    test "rotate -> trim -> flip -> resize -> background -> border -> adjust -> sharpen -> blur -> draw" do
      {:ok, pipeline} =
        Options.parse(
          "blur=200&sharp=20&bri=10&border=2,fff&bg=000&w=200&fit=crop&flip=h&trim=auto&rot=90"
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
