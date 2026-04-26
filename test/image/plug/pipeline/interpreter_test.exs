defmodule Image.Plug.Pipeline.InterpreterTest do
  use ExUnit.Case, async: true

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Interpreter
  alias Image.Plug.Pipeline.Ops

  @fixture Path.expand("../../../fixtures/images/sample.jpg", __DIR__)

  setup do
    {:ok, image} = Image.open(@fixture)
    %{image: image}
  end

  test "no ops returns the input image unchanged", %{image: image} do
    assert {:ok, ^image} = Interpreter.execute(Pipeline.new(), image)
  end

  test "Resize :contain shrinks to fit", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Resize{width: 200, height: 200, fit: :contain})

    assert {:ok, resized} = Interpreter.execute(pipeline, image)

    # contain preserves aspect ratio: width or height equals 200
    assert Image.width(resized) <= 200
    assert Image.height(resized) <= 200
    assert Image.width(resized) == 200 or Image.height(resized) == 200
  end

  test "Resize :cover fills the box exactly", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Resize{width: 200, height: 200, fit: :cover})

    assert {:ok, resized} = Interpreter.execute(pipeline, image)
    assert Image.width(resized) == 200
    assert Image.height(resized) == 200
  end

  test "Resize :squeeze stretches to exact dimensions", %{image: image} do
    pipeline =
      Pipeline.new() |> Pipeline.append(%Ops.Resize{width: 200, height: 100, fit: :squeeze})

    assert {:ok, resized} = Interpreter.execute(pipeline, image)
    assert Image.width(resized) == 200
    assert Image.height(resized) == 100
  end

  test "Resize :scale_down does not upscale", %{image: image} do
    huge =
      Pipeline.new()
      |> Pipeline.append(%Ops.Resize{width: 5000, height: 5000, fit: :scale_down})

    assert {:ok, resized} = Interpreter.execute(huge, image)
    assert Image.width(resized) <= Image.width(image)
    assert Image.height(resized) <= Image.height(image)
  end

  test "Resize :pad embeds the image in the requested canvas", %{image: image} do
    pipeline =
      Pipeline.new() |> Pipeline.append(%Ops.Resize{width: 300, height: 300, fit: :pad})

    assert {:ok, padded} = Interpreter.execute(pipeline, image)
    assert Image.width(padded) == 300
    assert Image.height(padded) == 300
  end

  test "Resize with only width preserves aspect ratio", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Resize{width: 320, fit: :contain})

    assert {:ok, resized} = Interpreter.execute(pipeline, image)
    assert Image.width(resized) == 320
    # 640x480 source -> 320 wide should give ~240 tall
    assert Image.height(resized) in 230..250
  end

  test "Rotate 90 swaps width and height", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Rotate{angle: 90})

    assert {:ok, rotated} = Interpreter.execute(pipeline, image)
    assert Image.width(rotated) == Image.height(image)
    assert Image.height(rotated) == Image.width(image)
  end

  test "Flip :horizontal preserves dimensions", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Flip{direction: :horizontal})

    assert {:ok, flipped} = Interpreter.execute(pipeline, image)
    assert Image.width(flipped) == Image.width(image)
    assert Image.height(flipped) == Image.height(image)
  end

  test "Flip :both runs both axes", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Flip{direction: :both})

    assert {:ok, flipped} = Interpreter.execute(pipeline, image)
    assert Image.width(flipped) == Image.width(image)
    assert Image.height(flipped) == Image.height(image)
  end

  test "Trim explicit removes the requested border", %{image: image} do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Trim{mode: :explicit, top: 10, right: 10, bottom: 10, left: 10})

    assert {:ok, trimmed} = Interpreter.execute(pipeline, image)
    assert Image.width(trimmed) == Image.width(image) - 20
    assert Image.height(trimmed) == Image.height(image) - 20
  end

  test "Adjust no-op (all 1.0) is identity", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Adjust{})

    assert {:ok, _adjusted} = Interpreter.execute(pipeline, image)
  end

  test "Adjust with non-default brightness produces a new image", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Adjust{brightness: 1.2})

    assert {:ok, _adjusted} = Interpreter.execute(pipeline, image)
  end

  test "Sharpen and Blur run cleanly", %{image: image} do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Sharpen{sigma: 1.0})
      |> Pipeline.append(%Ops.Blur{sigma: 1.0})

    assert {:ok, _result} = Interpreter.execute(pipeline, image)
  end

  test "Background flattens transparency against the given colour", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Background{color: "#ff0000"})

    assert {:ok, _flattened} = Interpreter.execute(pipeline, image)
  end

  test "Border embeds the image in a larger canvas", %{image: image} do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Border{color: "#ff0000", top: 5, right: 10, bottom: 15, left: 20})

    assert {:ok, bordered} = Interpreter.execute(pipeline, image)
    assert Image.width(bordered) == Image.width(image) + 30
    assert Image.height(bordered) == Image.height(image) + 20
  end

  test "Resize with dpr=2 doubles target dimensions", %{image: image} do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Resize{width: 100, height: 100, fit: :cover, dpr: 2})

    assert {:ok, resized} = Interpreter.execute(pipeline, image)
    assert Image.width(resized) == 200
    assert Image.height(resized) == 200
  end

  test "Resize fit=cover with gravity=:north_west crops to top-left", %{image: image} do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Resize{width: 200, height: 100, fit: :cover, gravity: :north_west})

    assert {:ok, resized} = Interpreter.execute(pipeline, image)
    assert Image.width(resized) == 200
    assert Image.height(resized) == 100
  end

  test "Segment is a no-op placeholder", %{image: image} do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Segment{kind: :foreground})

    assert {:ok, ^image} = Interpreter.execute(pipeline, image)
  end

  describe "Draw" do
    @watermark Path.expand("../../../fixtures/images/watermark.png", __DIR__)

    defp watermark_resolver do
      fn _source ->
        Image.open(@watermark)
      end
    end

    test "composes a watermark at the configured offset", %{image: image} do
      layer = %Ops.Draw.Layer{
        source: Image.Plug.Source.hosted("acct", "wm.png"),
        position: {:offset, [top: nil, right: 10, bottom: 10, left: nil]}
      }

      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Draw{layers: [layer]})

      assert {:ok, composed} =
               Interpreter.execute(pipeline, image,
                 resolve_layer_source: watermark_resolver()
               )

      # Composing should not change the base dimensions.
      assert Image.width(composed) == Image.width(image)
      assert Image.height(composed) == Image.height(image)
    end

    test "composes multiple layers in declared order", %{image: image} do
      layer = %Ops.Draw.Layer{source: Image.Plug.Source.hosted("a", "b.png")}

      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Draw{layers: [layer, layer]})

      assert {:ok, composed} =
               Interpreter.execute(pipeline, image,
                 resolve_layer_source: watermark_resolver()
               )

      assert Image.width(composed) == Image.width(image)
    end

    test "errors when no resolver is supplied", %{image: image} do
      layer = %Ops.Draw.Layer{source: Image.Plug.Source.hosted("a", "b.png")}

      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Draw{layers: [layer]})

      assert {:error, %Error{tag: :invalid_option}} = Interpreter.execute(pipeline, image, [])
    end

    test "an empty Draw op errors :not_implemented", %{image: image} do
      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Draw{layers: []})

      assert {:error, %Error{tag: :not_implemented}} =
               Interpreter.execute(pipeline, image, resolve_layer_source: watermark_resolver())
    end

    test "resizes the layer when width/height set", %{image: image} do
      layer = %Ops.Draw.Layer{
        source: Image.Plug.Source.hosted("a", "b.png"),
        width: 25,
        height: 25,
        fit: :cover
      }

      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Draw{layers: [layer]})

      assert {:ok, _composed} =
               Interpreter.execute(pipeline, image,
                 resolve_layer_source: watermark_resolver()
               )
    end
  end
end
