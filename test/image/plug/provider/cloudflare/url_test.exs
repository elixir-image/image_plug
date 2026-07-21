defmodule Image.Plug.Provider.Cloudflare.URLTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Provider.Cloudflare.URL

  alias Image.Plug.{Error, Source}
  alias Image.Plug.Provider.Cloudflare.URL

  defp build_conn(path) do
    %Plug.Conn{
      path_info: String.split(path, "/", trim: true),
      request_path: path
    }
  end

  describe "remote-image transform form" do
    test "parses /cdn-cgi/image/<options>/<absolute-path>" do
      conn = build_conn("/cdn-cgi/image/width=200,fit=cover/foo/bar.jpg")

      assert {:ok, %{shape: :remote, options: "width=200,fit=cover", source: source}} =
               URL.parse(conn, [])

      assert %Source{kind: :path, ref: "/foo/bar.jpg"} = source
    end

    test "parses an https:// source" do
      conn = build_conn("/cdn-cgi/image/width=200/https://example.com/x.jpg")

      assert {:ok, %{source: %Source{kind: :url, ref: ref}}} = URL.parse(conn, [])
      assert ref == "https://example.com/x.jpg"
    end

    test "parses an http:// source" do
      conn = build_conn("/cdn-cgi/image/width=200/http://example.com/x.jpg")

      assert {:ok, %{source: %Source{kind: :url, ref: "http://example.com/x.jpg"}}} =
               URL.parse(conn, [])
    end

    test "honours :mount prefix" do
      conn = build_conn("/img/cdn-cgi/image/width=200/foo.jpg")

      assert {:ok, %{source: %Source{kind: :path, ref: "/foo.jpg"}}} =
               URL.parse(conn, mount: "/img")
    end

    test "is unrecognised when the request is not under :mount" do
      conn = build_conn("/something/else/cdn-cgi/image/width=200/foo.jpg")

      assert :unrecognised = URL.parse(conn, mount: "/img")
    end

    test "is unrecognised when the path has no cdn-cgi/image marker" do
      conn = build_conn("/some/other/path.jpg")

      assert :unrecognised = URL.parse(conn, [])
    end

    test "rejects empty options" do
      conn = build_conn("/cdn-cgi/image//foo.jpg")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, [])
    end

    test "rejects missing source" do
      conn = build_conn("/cdn-cgi/image/width=200")

      assert {:error, %Error{tag: :malformed_url}} = URL.parse(conn, [])
    end
  end

  describe "hosted-image delivery form" do
    test "tail without `=` is treated as a variant name" do
      conn = build_conn("/acct123/img456/thumbnail")

      assert {:ok, %{shape: :hosted, variant: "thumbnail", options: nil, source: source}} =
               URL.parse(conn, hosted_account_hash: "acct123")

      assert source.kind == :hosted
      assert source.ref == {"acct123", "img456"}
    end

    test "tail with `=` is treated as an options string" do
      conn = build_conn("/acct123/img456/width=200,fit=cover")

      assert {:ok, %{shape: :hosted, options: "width=200,fit=cover", variant: nil}} =
               URL.parse(conn, hosted_account_hash: "acct123")
    end

    test "missing tail maps to the implicit `public` variant" do
      conn = build_conn("/acct123/img456")

      assert {:ok, %{shape: :hosted, variant: "public"}} =
               URL.parse(conn, hosted_account_hash: "acct123")
    end

    test "is unrecognised when the account hash does not match config" do
      conn = build_conn("/wrongacct/img456/thumbnail")

      assert :unrecognised = URL.parse(conn, hosted_account_hash: "acct123")
    end

    test "hosted form is unrecognised when :hosted_account_hash is unset" do
      conn = build_conn("/acct123/img456/thumbnail")

      assert :unrecognised = URL.parse(conn, [])
    end
  end
end
