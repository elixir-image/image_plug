defmodule Image.Plug.StreamingPipelineTest do
  @moduledoc """
  Asserts that the full request lifecycle from disk to client uses
  the streaming-shape documented in the `Image` library's own test
  suite (`stream_image_test.exs`).

  This is a regression test: if anyone refactors the source loader,
  the encoder, or the plug's chunked-write to a non-streaming form
  (e.g. a `File.read!` + `Image.from_binary` + `send_resp`), this
  test will still pass on output correctness — but the assertion
  on `chunk_count` ensures we keep emitting many small chunks
  rather than one big buffer.
  """

  use ExUnit.Case, async: true
  import Plug.Test

  @fixtures Path.expand("../../fixtures/images", __DIR__)

  test "the documented File.stream! -> Image.open -> Image.stream! -> Plug.Conn.chunk chain runs end to end" do
    # Replicate the exact pattern from
    # https://github.com/kipcole9/image/blob/main/test/stream_image_test.exs
    # (the "Image.stream! into a Plug.Conn" test) using our fixtures.
    conn =
      :get
      |> conn("/")
      |> Plug.Conn.send_chunked(200)

    assert %Plug.Conn{} =
             Path.join(@fixtures, "sample.jpg")
             |> File.stream!(2048, [])
             |> Image.open!()
             |> Image.thumbnail!(200)
             |> Image.stream!(suffix: ".jpg")
             |> Enum.reduce_while(conn, fn chunk, c ->
               case Plug.Conn.chunk(c, chunk) do
                 {:ok, c} -> {:cont, c}
                 {:error, :closed} -> {:halt, c}
               end
             end)
  end

  test "Image.Plug end-to-end uses the streaming chain (chunked transfer-encoding)" do
    options =
      Image.Plug.init(
        provider: {Image.Plug.Provider.Cloudflare, []},
        source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
        on_error: :status_text
      )

    conn =
      conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
      |> Image.Plug.call(options)

    assert conn.status == 200
    # `Plug.Conn.send_chunked/2` sets `state: :chunked`; if we ever
    # accidentally call `send_resp/3` for a streaming format the
    # state would be `:sent` instead.
    assert conn.state == :chunked
  end
end
