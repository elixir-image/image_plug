defmodule Image.Plug.PipelineTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Pipeline

  alias Image.Plug.Pipeline
  alias Image.Plug.Pipeline.Ops

  test "new/0 returns an empty pipeline with default Format" do
    pipeline = Pipeline.new()

    assert pipeline.ops == []
    assert pipeline.on_error == :auto
    assert pipeline.provider == nil
    assert %Ops.Format{type: :auto, quality: 85, metadata: :copyright} = pipeline.output
  end

  test "new/1 accepts overrides" do
    output = %Ops.Format{type: :webp, quality: 70}
    pipeline = Pipeline.new(output: output, on_error: :raise, provider: SomeProvider)

    assert pipeline.output == output
    assert pipeline.on_error == :raise
    assert pipeline.provider == SomeProvider
  end

  test "append/2 adds an op to the end" do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Rotate{angle: 90})
      |> Pipeline.append(%Ops.Flip{direction: :horizontal})

    assert [%Ops.Rotate{angle: 90}, %Ops.Flip{direction: :horizontal}] = pipeline.ops
  end

  test "put_output/2 replaces the format" do
    pipeline =
      Pipeline.new()
      |> Pipeline.put_output(%Ops.Format{type: :png, quality: 100, metadata: :none})

    assert %Ops.Format{type: :png} = pipeline.output
  end

  test "every op struct module is loadable and has a struct" do
    for op_module <- [
          Ops.Rotate,
          Ops.Trim,
          Ops.Flip,
          Ops.Resize,
          Ops.Background,
          Ops.Adjust,
          Ops.Sharpen,
          Ops.Blur,
          Ops.Border,
          Ops.Draw,
          Ops.Draw.Layer,
          Ops.Format,
          Ops.Segment
        ] do
      assert Code.ensure_loaded?(op_module),
             "#{inspect(op_module)} could not be loaded"

      assert function_exported?(op_module, :__struct__, 0),
             "#{inspect(op_module)} does not define a struct"
    end
  end

  test "Resize defaults match the documented contract" do
    assert %Ops.Resize{
             width: nil,
             height: nil,
             fit: :contain,
             gravity: :center,
             upscale?: true,
             dpr: 1,
             face_zoom: +0.0
           } = %Ops.Resize{}
  end

  test "Adjust defaults are all 1.0 (no-op)" do
    assert %Ops.Adjust{brightness: +1.0, contrast: +1.0, gamma: +1.0, saturation: +1.0} =
             %Ops.Adjust{}
  end

  test "Flip requires an explicit direction" do
    assert_raise ArgumentError, fn ->
      struct!(Ops.Flip, [])
    end
  end

  test "Border requires an explicit color" do
    assert_raise ArgumentError, fn ->
      struct!(Ops.Border, [])
    end
  end
end
