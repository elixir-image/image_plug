defmodule Image.Plug.Provider.Imgix.URLTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.Imgix.URL

  alias Image.Plug.{Error, Source}
  alias Image.Plug.Provider.Imgix.URL

  defp build_conn(path, query \\ "") do
    %Plug.Conn{
      path_info: String.split(path, "/", trim: true),
      request_path: path,
      query_string: query
    }
  end

  describe "web-folder source" do
    test "single-segment path" do
      conn = build_conn("/sunset.jpg", "w=200")

      assert {:ok, %{shape: :imgix, options: "w=200", source: source}} = URL.parse(conn, [])
      assert source == %Source{kind: :path, ref: "/sunset.jpg"}
    end

    test "nested path" do
      conn = build_conn("/photos/2026/sunset.jpg", "w=200&fit=crop")

      assert {:ok, %{source: %Source{kind: :path, ref: "/photos/2026/sunset.jpg"}}} =
               URL.parse(conn, [])
    end

    test "honours :mount prefix" do
      conn = build_conn("/img/photos/sunset.jpg")

      assert {:ok, %{source: %Source{kind: :path, ref: "/photos/sunset.jpg"}}} =
               URL.parse(conn, mount: "/img")
    end

    test "rejects paths not under :mount" do
      conn = build_conn("/other/photos/sunset.jpg")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, mount: "/img")
    end

    test "rejects empty source path" do
      conn = build_conn("/img", "w=200")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, mount: "/img")
    end
  end

  describe "web-proxy source" do
    test "single percent-encoded https URL" do
      encoded = URI.encode("https://assets.example.com/sunset.jpg", &URI.char_unreserved?/1)
      conn = build_conn("/" <> encoded, "w=200")

      assert {:ok, %{source: %Source{kind: :url, ref: "https://assets.example.com/sunset.jpg"}}} =
               URL.parse(conn, [])
    end

    test "single percent-encoded http URL" do
      encoded = URI.encode("http://assets.example.com/sunset.jpg", &URI.char_unreserved?/1)
      conn = build_conn("/" <> encoded)

      assert {:ok, %{source: %Source{kind: :url, ref: "http://assets.example.com/sunset.jpg"}}} =
               URL.parse(conn, [])
    end

    test "multi-segment path with http-looking first segment is treated as :path" do
      # Imgix's convention is one URL-encoded segment for proxy.
      # If the user has a folder literally named "http:" they meant
      # a path source.
      conn = build_conn("/http:/example.com/x.jpg")

      assert {:ok, %{source: %Source{kind: :path}}} = URL.parse(conn, [])
    end
  end
end
