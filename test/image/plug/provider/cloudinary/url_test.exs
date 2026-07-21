defmodule Image.Plug.Provider.Cloudinary.URLTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.Cloudinary.URL

  alias Image.Plug.{Error, Source}
  alias Image.Plug.Provider.Cloudinary.URL

  defp build_conn(path, query \\ "") do
    %Plug.Conn{
      path_info: String.split(path, "/", trim: true),
      request_path: path,
      query_string: query
    }
  end

  describe "upload delivery" do
    test "single transform stage + simple source" do
      conn = build_conn("/demo/image/upload/w_200,c_fill/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w_200,c_fill"
      assert parsed.account == "demo"
      assert parsed.delivery == "upload"
      assert parsed.source == %Source{kind: :path, ref: "/sample.jpg"}
      assert parsed.signature == nil
    end

    test "no transform stage" do
      conn = build_conn("/demo/image/upload/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == ""
      assert parsed.source.ref == "/sample.jpg"
    end

    test "multi-stage transforms are flattened to one comma string" do
      conn = build_conn("/demo/image/upload/w_200,c_fill/e_blur:300/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w_200,c_fill,e_blur:300"
    end

    test "nested folder source" do
      conn = build_conn("/demo/image/upload/w_200/photos/2026/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w_200"
      assert parsed.source.ref == "/photos/2026/sample.jpg"
    end

    test "signed URL strips s--<sig>-- segment into :signature field" do
      conn = build_conn("/demo/image/upload/s--abc123def--/w_200/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.signature == "s--abc123def--"
      assert parsed.options == "w_200"
      assert parsed.source.ref == "/sample.jpg"
    end
  end

  describe "fetch delivery (web-proxy)" do
    test "absolute https source" do
      conn = build_conn("/demo/image/fetch/w_200/https:/assets.example.com/sunset.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.delivery == "fetch"
      assert parsed.source == %Source{kind: :url, ref: "https://assets.example.com/sunset.jpg"}
    end
  end

  describe "mount + account" do
    test "honours :mount prefix" do
      conn = build_conn("/img/demo/image/upload/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, mount: "/img")
      assert parsed.account == "demo"
      assert parsed.source.ref == "/sample.jpg"
    end

    test "passes through paths not under :mount" do
      conn = build_conn("/other/demo/image/upload/sample.jpg")

      assert :unrecognised = URL.parse(conn, mount: "/img")
    end

    test "rejects mismatched account when :account is configured" do
      conn = build_conn("/other/image/upload/sample.jpg")

      assert {:error, %Error{tag: :malformed_url}} =
               URL.parse(conn, account: "demo")
    end
  end

  describe "malformed input" do
    test "missing source segment" do
      conn = build_conn("/demo/image/upload")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, [])
    end

    test "fewer than 4 segments" do
      conn = build_conn("/demo/image")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, [])
    end
  end
end
