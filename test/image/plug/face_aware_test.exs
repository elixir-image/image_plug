defmodule Image.Plug.FaceAwareTest do
  @moduledoc """
  Tests for the `Image.Plug.FaceAware` seam.

  These tests run regardless of whether `:image_vision` is
  installed — when absent, the module returns
  `{:error, :unavailable}` and the assertions verify that
  contract. End-to-end face-aware crop behaviour is tested
  in the `image_vision` test suite where
  `Image.FaceDetection` is loaded.
  """
  use ExUnit.Case, async: true

  alias Image.Plug.FaceAware

  @fixture Path.expand("../../fixtures/images/sample.jpg", __DIR__)

  describe "available?/0" do
    test "is a boolean" do
      assert FaceAware.available?() in [true, false]
    end

    test "matches Code.ensure_loaded?(Image.FaceDetection)" do
      assert FaceAware.available?() == Code.ensure_loaded?(Image.FaceDetection)
    end
  end

  describe "face_crop/2 — without :image_vision" do
    @describetag :skip_if_face_detection_loaded

    setup do
      if Code.ensure_loaded?(Image.FaceDetection) do
        :ignored
      else
        :ok
      end
    end

    test "returns {:error, :unavailable} when Image.FaceDetection isn't loaded" do
      if FaceAware.available?() do
        :skipped
      else
        {:ok, image} = Image.open(@fixture)
        assert {:error, :unavailable} = FaceAware.face_crop(image, 0.5)
      end
    end
  end

  describe "pixelate_faces/2 — without :image_vision" do
    test "returns {:error, :unavailable} when Image.FaceDetection isn't loaded" do
      if FaceAware.available?() do
        :skipped
      else
        {:ok, image} = Image.open(@fixture)
        assert {:error, :unavailable} = FaceAware.pixelate_faces(image, 0.05)
      end
    end
  end
end
