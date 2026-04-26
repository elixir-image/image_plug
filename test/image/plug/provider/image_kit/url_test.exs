defmodule Image.Plug.Provider.ImageKit.URLTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.ImageKit.URL

  alias Image.Plug.{Error, Source}
  alias Image.Plug.Provider.ImageKit.URL

  defp build_conn(path, query \\ "") do
    %Plug.Conn{
      path_info: String.split(path, "/", trim: true),
      request_path: path,
      query_string: query
    }
  end

  describe "path-prefix tr: form" do
    test "single transform stage + simple source" do
      conn = build_conn("/tr:w-200,h-100/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w-200,h-100"
      assert parsed.source == %Source{kind: :path, ref: "/sample.jpg"}
    end

    test "multi-stage chained transforms flatten with comma" do
      conn = build_conn("/tr:w-200,h-100:rt-90/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w-200,h-100,rt-90"
    end

    test "nested folder source" do
      conn = build_conn("/tr:w-200/photos/2026/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w-200"
      assert parsed.source.ref == "/photos/2026/sample.jpg"
    end
  end

  describe "query-string tr= form" do
    test "no path-prefix, transforms in query" do
      conn = build_conn("/sample.jpg", "tr=w-200,h-100")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w-200,h-100"
      assert parsed.source.ref == "/sample.jpg"
    end

    test "query stages flatten with comma" do
      conn = build_conn("/sample.jpg", "tr=w-200%3Art-90")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w-200,rt-90"
    end

    test "both path-prefix and query merge" do
      conn = build_conn("/tr:w-200/sample.jpg", "tr=q-80")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == "w-200,q-80"
    end
  end

  describe "mount + endpoint" do
    test "honours :mount prefix" do
      conn = build_conn("/img/tr:w-200/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, mount: "/img")
      assert parsed.source.ref == "/sample.jpg"
    end

    test "honours :endpoint prefix" do
      conn = build_conn("/your_id/tr:w-200/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, endpoint: "your_id")
      assert parsed.source.ref == "/sample.jpg"
    end

    test "rejects paths not under :mount" do
      conn = build_conn("/other/tr:w-200/sample.jpg")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, mount: "/img")
    end
  end

  describe "no transforms" do
    test "passthrough source with no tr: segment" do
      conn = build_conn("/sample.jpg")

      assert {:ok, parsed} = URL.parse(conn, [])
      assert parsed.options == ""
      assert parsed.source.ref == "/sample.jpg"
    end
  end

  describe "malformed input" do
    test "missing source segment under tr:" do
      conn = build_conn("/tr:w-200")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, [])
    end
  end
end
