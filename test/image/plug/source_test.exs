defmodule Image.Plug.SourceTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Source

  alias Image.Plug.{Error, Source}

  describe "path/1" do
    test "accepts an absolute path" do
      assert {:ok, %Source{kind: :path, ref: "/foo/bar.jpg"}} = Source.path("/foo/bar.jpg")
    end

    test "rejects a relative path" do
      assert {:error, %Error{tag: :invalid_option}} = Source.path("foo/bar.jpg")
    end

    test "rejects a path containing `..` segments" do
      assert {:error, %Error{tag: :invalid_option}} = Source.path("/foo/../etc/passwd")
    end
  end

  describe "url/1" do
    test "accepts http URLs" do
      assert {:ok, %Source{kind: :url, ref: "http://example.com/a.jpg"}} =
               Source.url("http://example.com/a.jpg")
    end

    test "accepts https URLs" do
      assert {:ok, %Source{kind: :url}} = Source.url("https://example.com/a.jpg")
    end

    test "rejects URLs without a scheme" do
      assert {:error, %Error{tag: :invalid_option}} = Source.url("example.com/a.jpg")
    end

    test "rejects file:// URLs" do
      assert {:error, %Error{tag: :invalid_option}} = Source.url("file:///etc/passwd")
    end

    test "rejects malformed URLs" do
      assert {:error, %Error{tag: :invalid_option}} = Source.url("not a url at all")
    end
  end

  describe "hosted/2" do
    test "builds a hosted source" do
      assert %Source{kind: :hosted, ref: {"acct", "id"}} = Source.hosted("acct", "id")
    end
  end
end
