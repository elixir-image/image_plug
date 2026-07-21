defmodule Image.Plug.Provider.PassthroughTest do
  use ExUnit.Case, async: true
  import Plug.Test

  # Every provider must pass through (return `{:ok, :skip}`) a request
  # whose path is not under its configured mount, so `plug Image.Plug`
  # is safe to mount ahead of a host application's router regardless of
  # which provider is configured.
  @providers [
    {Image.Plug.Provider.Cloudflare, [mount: "/img"]},
    {Image.Plug.Provider.Imgix, [mount: "/img"]},
    {Image.Plug.Provider.Cloudinary, [mount: "/img"]},
    {Image.Plug.Provider.ImageKit, [mount: "/img"]},
    {Image.Plug.Provider.IIIF, [mount: "/img"]}
  ]

  for {provider, opts} <- @providers do
    test "#{inspect(provider)} passes through a request not under its mount" do
      conn = conn(:get, "/dashboard/users/42")
      assert {:ok, :skip} = unquote(provider).parse(conn, unquote(Macro.escape(opts)))
    end
  end

  test "Cloudflare also passes through a non-image URL at the mount root" do
    conn = conn(:get, "/favicon.ico")
    assert {:ok, :skip} = Image.Plug.Provider.Cloudflare.parse(conn, [])
  end
end
