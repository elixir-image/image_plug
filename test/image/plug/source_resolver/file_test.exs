defmodule Image.Plug.SourceResolver.FileTest do
  use ExUnit.Case, async: true

  alias Image.Plug.{Error, Source}
  alias Image.Plug.SourceResolver.File, as: FileResolver

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  describe "load/2" do
    test "opens an existing file under the configured root" do
      {:ok, source} = Source.path("/sample.jpg")

      assert {:ok, image, meta} = FileResolver.load(source, root: @fixtures)
      assert match?(%Vix.Vips.Image{}, image)
      assert meta.content_type == "image/jpeg"
      assert is_binary(meta.etag_seed) and byte_size(meta.etag_seed) > 0
      assert meta.byte_size > 0
      assert %DateTime{} = meta.last_modified
    end

    test "rejects a non-existent file with :source_not_found" do
      {:ok, source} = Source.path("/nope.jpg")

      assert {:error, %Error{tag: :source_not_found}} =
               FileResolver.load(source, root: @fixtures)
    end

    test "rejects path traversal attempts that escape the root" do
      # Source.path/1 itself blocks `..` segments; bypass it to test the
      # second-line-of-defence in the resolver.
      escape = %Source{kind: :path, ref: "/../etc/passwd"}

      assert {:error, %Error{tag: :invalid_option, message: message}} =
               FileResolver.load(escape, root: @fixtures)

      assert message =~ "escapes the configured root" or message =~ "absolute"
    end

    test "rejects a non-:path source" do
      hosted = Source.hosted("acct", "id")

      assert {:error, %Error{tag: :invalid_option}} =
               FileResolver.load(hosted, root: @fixtures)
    end

    test "rejects a missing :root option" do
      {:ok, source} = Source.path("/sample.jpg")

      assert {:error, %Error{tag: :invalid_option}} = FileResolver.load(source, [])
    end

    test "rejects a relative :root option" do
      {:ok, source} = Source.path("/sample.jpg")

      assert {:error, %Error{tag: :invalid_option}} =
               FileResolver.load(source, root: "test/fixtures/images")
    end
  end
end
