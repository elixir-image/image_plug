defmodule Image.Plug.Pipeline.EncoderTest do
  use ExUnit.Case, async: true

  alias Image.Plug.Pipeline.Encoder
  alias Image.Plug.Pipeline.Ops

  @fixture Path.expand("../../../fixtures/images/sample.jpg", __DIR__)

  setup do
    {:ok, image} = Image.open(@fixture)
    %{image: image}
  end

  describe "stream output" do
    for {type, expected_content_type, magic} <- [
          {:jpeg, "image/jpeg", <<0xFF, 0xD8, 0xFF>>},
          {:baseline_jpeg, "image/jpeg", <<0xFF, 0xD8, 0xFF>>},
          {:png, "image/png", <<0x89, "PNG">>},
          {:webp, "image/webp", "RIFF"}
        ] do
      test "#{type} streams with the right content-type and magic bytes", %{image: image} do
        format = %Ops.Format{type: unquote(type), quality: 80, metadata: :copyright}

        assert {:ok, {:stream, stream}, unquote(expected_content_type)} = Encoder.encode(image, format)

        bytes = Enum.into(stream, <<>>)
        assert byte_size(bytes) > 0
        assert binary_part(bytes, 0, byte_size(unquote(magic))) == unquote(magic)
      end
    end
  end

  describe "buffered output" do
    test "JPEG returns iodata with correct magic bytes", %{image: image} do
      format = %Ops.Format{type: :jpeg, quality: 80, metadata: :copyright}

      assert {:ok, {:bytes, bytes}, "image/jpeg"} = Encoder.encode(image, format, buffer: :bytes)

      flat = IO.iodata_to_binary(bytes)
      assert byte_size(flat) > 0
      assert binary_part(flat, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end
  end

  describe "json output" do
    test "returns the metadata shape with width/height/bands/has_alpha", %{image: image} do
      assert {:ok, {:bytes, iodata}, "application/json"} =
               Encoder.encode(image, %Ops.Format{type: :json})

      decoded = :json.decode(IO.iodata_to_binary(iodata))
      assert decoded["width"] == Image.width(image)
      assert decoded["height"] == Image.height(image)
      assert is_integer(decoded["bands"])
      assert is_boolean(decoded["has_alpha"])
    end
  end

  describe "auto format" do
    test "picks AVIF when client accepts AVIF and libvips supports it", %{image: image} do
      result =
        Encoder.encode(image, %Ops.Format{type: :auto},
          accept: "image/avif,image/webp,image/*",
          source_content_type: "image/jpeg"
        )

      cond do
        Image.Plug.Capabilities.avif_write?() ->
          assert {:ok, _body, "image/avif"} = result

        true ->
          # AVIF unsupported -> falls through to WebP via the soft fallback.
          assert {:ok, _body, "image/webp", _headers} = result
      end
    end

    test "picks WebP when AVIF is not in Accept", %{image: image} do
      assert {:ok, _body, "image/webp"} =
               Encoder.encode(image, %Ops.Format{type: :auto},
                 accept: "image/webp",
                 source_content_type: "image/jpeg"
               )
    end

    test "falls back to source content-type when no preferred type is acceptable", %{image: image} do
      assert {:ok, _body, "image/jpeg"} =
               Encoder.encode(image, %Ops.Format{type: :auto},
                 accept: "text/html",
                 source_content_type: "image/jpeg"
               )
    end
  end

  describe "avif fallback" do
    test "encodes WebP and adds the fallback header when libvips lacks AVIF", %{image: image} do
      unless Image.Plug.Capabilities.avif_write?() do
        assert {:ok, _body, "image/webp", headers} =
                 Encoder.encode(image, %Ops.Format{type: :avif, quality: 60})

        assert {"x-image-plug-format-fallback", "avif->webp"} in headers
      end
    end

    test "encodes AVIF directly when libvips supports it", %{image: image} do
      if Image.Plug.Capabilities.avif_write?() do
        assert {:ok, _body, "image/avif"} =
                 Encoder.encode(image, %Ops.Format{type: :avif, quality: 60})
      end
    end
  end
end
