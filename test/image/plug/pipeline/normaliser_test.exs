defmodule Image.Plug.Pipeline.NormaliserTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Pipeline.Normaliser

  alias Image.Plug.{Error, Pipeline}
  alias Image.Plug.Pipeline.Normaliser
  alias Image.Plug.Pipeline.Ops

  test "drops a Resize op with no dimensions" do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Resize{})

    assert {:ok, %Pipeline{ops: []}} = Normaliser.normalise(pipeline)
  end

  test "keeps a Resize op with width set" do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Resize{width: 200})

    assert {:ok, %Pipeline{ops: [%Ops.Resize{width: 200}]}} = Normaliser.normalise(pipeline)
  end

  test "drops Rotate{angle: 0}" do
    pipeline = Pipeline.new() |> Pipeline.append(%Ops.Rotate{angle: 0})

    assert {:ok, %Pipeline{ops: []}} = Normaliser.normalise(pipeline)
  end

  test "rejects more than one Resize op" do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Resize{width: 100})
      |> Pipeline.append(%Ops.Resize{width: 200})

    assert {:error, %Error{tag: :invalid_option}} = Normaliser.normalise(pipeline)
  end

  test "is idempotent" do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Rotate{angle: 0})
      |> Pipeline.append(%Ops.Resize{width: 100})

    {:ok, once} = Normaliser.normalise(pipeline)
    {:ok, twice} = Normaliser.normalise(once)

    assert once == twice
  end

  describe "canonical ordering (Sharp-style)" do
    test "reorders ops into canonical position regardless of input order" do
      # Construct in *reverse* canonical order. Normaliser must
      # reorder to: Trim -> Background -> Resize -> Rotate -> Flip
      # -> Border -> Adjust -> Colorspace -> ReplaceColor -> Blur ->
      # Sharpen -> Draw.
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Sharpen{sigma: 1.0})
        |> Pipeline.append(%Ops.Blur{sigma: 1.0})
        |> Pipeline.append(%Ops.ReplaceColor{to: "#000000", from: "#ffffff", threshold: 30})
        |> Pipeline.append(%Ops.Colorspace{target: :srgb})
        |> Pipeline.append(%Ops.Adjust{brightness: 1.1})
        |> Pipeline.append(%Ops.Border{color: "#fff", top: 1, right: 1, bottom: 1, left: 1})
        |> Pipeline.append(%Ops.Flip{direction: :horizontal})
        |> Pipeline.append(%Ops.Rotate{angle: 90})
        |> Pipeline.append(%Ops.Resize{width: 200})
        |> Pipeline.append(%Ops.Background{color: "#000"})
        |> Pipeline.append(%Ops.Trim{mode: :border})

      {:ok, normalised} = Normaliser.normalise(pipeline)

      assert Enum.map(normalised.ops, & &1.__struct__) == [
               Ops.Trim,
               Ops.Background,
               Ops.Resize,
               Ops.Rotate,
               Ops.Flip,
               Ops.Border,
               Ops.Adjust,
               Ops.Colorspace,
               Ops.ReplaceColor,
               Ops.Blur,
               Ops.Sharpen
             ]
    end

    test "Colorspace lands between Adjust and ReplaceColor" do
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.ReplaceColor{to: "#000", from: "#fff"})
        |> Pipeline.append(%Ops.Colorspace{target: :bw})
        |> Pipeline.append(%Ops.Adjust{brightness: 1.1})

      {:ok, %Pipeline{ops: ops}} = Normaliser.normalise(pipeline)

      assert [%Ops.Adjust{}, %Ops.Colorspace{}, %Ops.ReplaceColor{}] = ops
    end

    test "ReplaceColor lands between Adjust and Blur" do
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Blur{sigma: 1.0})
        |> Pipeline.append(%Ops.ReplaceColor{to: "#000000", from: "#ffffff"})
        |> Pipeline.append(%Ops.Adjust{brightness: 1.1})

      {:ok, %Pipeline{ops: ops}} = Normaliser.normalise(pipeline)

      assert [%Ops.Adjust{}, %Ops.ReplaceColor{}, %Ops.Blur{}] = ops
    end

    test "blur runs before sharpen (Sharp's rule)" do
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Sharpen{sigma: 1.0})
        |> Pipeline.append(%Ops.Blur{sigma: 1.0})

      {:ok, normalised} = Normaliser.normalise(pipeline)

      assert [%Ops.Blur{}, %Ops.Sharpen{}] = normalised.ops
    end

    test "thumbnail-style Resize lands before any post-resize op" do
      # Regression: the TODO calls out that Image.thumbnail/3 must
      # run before other transforms to benefit from libvips'
      # shrink-on-load. The normaliser must guarantee this even when
      # the user appends Resize last.
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Adjust{brightness: 1.2})
        |> Pipeline.append(%Ops.Sharpen{sigma: 1.0})
        |> Pipeline.append(%Ops.Resize{width: 200})

      {:ok, %Pipeline{ops: ops}} = Normaliser.normalise(pipeline)

      resize_index = Enum.find_index(ops, &match?(%Ops.Resize{}, &1))
      adjust_index = Enum.find_index(ops, &match?(%Ops.Adjust{}, &1))
      sharpen_index = Enum.find_index(ops, &match?(%Ops.Sharpen{}, &1))

      assert resize_index < adjust_index
      assert resize_index < sharpen_index
    end

    test "trim runs before resize so the resize sees only meaningful pixels" do
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Resize{width: 200})
        |> Pipeline.append(%Ops.Trim{mode: :border})

      {:ok, %Pipeline{ops: [%Ops.Trim{}, %Ops.Resize{}]}} = Normaliser.normalise(pipeline)
    end
  end

  describe "no-op folding" do
    test "drops Sharpen{sigma: 0}" do
      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Sharpen{sigma: 0})

      assert {:ok, %Pipeline{ops: []}} = Normaliser.normalise(pipeline)
    end

    test "drops Blur{sigma: 0}" do
      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Blur{sigma: 0})

      assert {:ok, %Pipeline{ops: []}} = Normaliser.normalise(pipeline)
    end

    test "drops Adjust with all multipliers 1.0" do
      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Adjust{})

      assert {:ok, %Pipeline{ops: []}} = Normaliser.normalise(pipeline)
    end

    test "keeps Adjust when any multiplier differs from 1.0" do
      pipeline = Pipeline.new() |> Pipeline.append(%Ops.Adjust{brightness: 1.2})

      assert {:ok, %Pipeline{ops: [%Ops.Adjust{}]}} = Normaliser.normalise(pipeline)
    end

    test "drops Border with all-zero sides" do
      pipeline =
        Pipeline.new() |> Pipeline.append(%Ops.Border{color: "#fff"})

      assert {:ok, %Pipeline{ops: []}} = Normaliser.normalise(pipeline)
    end

    test "drops explicit Trim with all-zero sides" do
      pipeline =
        Pipeline.new() |> Pipeline.append(%Ops.Trim{mode: :explicit})

      assert {:ok, %Pipeline{ops: []}} = Normaliser.normalise(pipeline)
    end
  end

  describe "extended cardinality enforcement" do
    test "rejects more than one Trim op" do
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Trim{mode: :border})
        |> Pipeline.append(%Ops.Trim{mode: :border})

      assert {:error, %Error{tag: :invalid_option}} = Normaliser.normalise(pipeline)
    end

    test "rejects more than one Adjust op" do
      pipeline =
        Pipeline.new()
        |> Pipeline.append(%Ops.Adjust{brightness: 1.1})
        |> Pipeline.append(%Ops.Adjust{contrast: 1.1})

      assert {:error, %Error{tag: :invalid_option}} = Normaliser.normalise(pipeline)
    end
  end

  test "is idempotent across reordering and folding" do
    pipeline =
      Pipeline.new()
      |> Pipeline.append(%Ops.Sharpen{sigma: 1.0})
      |> Pipeline.append(%Ops.Resize{width: 100})
      |> Pipeline.append(%Ops.Adjust{brightness: 1.1})

    {:ok, once} = Normaliser.normalise(pipeline)
    {:ok, twice} = Normaliser.normalise(once)
    {:ok, thrice} = Normaliser.normalise(twice)

    assert once == twice
    assert twice == thrice
  end
end
