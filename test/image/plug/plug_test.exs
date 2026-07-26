defmodule Image.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Image.Plug.{Error, Options}

  @fixtures Path.expand("../../fixtures/images", __DIR__)

  defmodule StubProvider do
    @behaviour Image.Plug.Provider

    @impl true
    def parse(_conn, _options) do
      {:error, Error.new(:not_implemented, "stub")}
    end
  end

  defmodule StubResolver do
    @behaviour Image.Plug.SourceResolver

    @impl true
    def load(_source, _options) do
      {:error, Error.new(:not_implemented, "stub")}
    end
  end

  defp build_options(extra \\ []) do
    [
      provider: {Image.Plug.Provider.Cloudflare, []},
      source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
      # Tests assert specific status codes, so opt out of the default
      # `:auto` policy which renders an error image (in dev/test).
      on_error: :status_text
    ]
    |> Keyword.merge(extra)
    |> Image.Plug.init()
  end

  describe "init/1" do
    test "validates and returns an Options struct" do
      options =
        Image.Plug.init(provider: {StubProvider, []}, source_resolver: {StubResolver, []})

      assert %Options{provider: StubProvider, source_resolver: StubResolver, on_error: :auto} =
               options
    end

    test "accepts a bare module as shorthand for {module, []}" do
      options = Image.Plug.init(provider: StubProvider, source_resolver: StubResolver)

      assert options.provider_options == []
      assert options.source_resolver_options == []
    end

    test "raises when :provider is missing" do
      assert_raise ArgumentError, ~r/required option :provider/, fn ->
        Image.Plug.init(source_resolver: {StubResolver, []})
      end
    end

    test "raises when :source_resolver is missing" do
      assert_raise ArgumentError, ~r/required option :source_resolver/, fn ->
        Image.Plug.init(provider: {StubProvider, []})
      end
    end

    test "rejects an invalid :on_error value" do
      assert_raise ArgumentError, ~r/:on_error/, fn ->
        Image.Plug.init(
          provider: {StubProvider, []},
          source_resolver: {StubResolver, []},
          on_error: :wat
        )
      end
    end

    test "accepts {:status, code} for :on_error" do
      options =
        Image.Plug.init(
          provider: {StubProvider, []},
          source_resolver: {StubResolver, []},
          on_error: {:status, 500}
        )

      assert options.on_error == {:status, 500}
    end
  end

  describe "runtime configuration (:otp_app)" do
    test "init/1 with :otp_app defers resolution to a runtime tuple" do
      assert {:runtime, :image_plug, Image.Plug, []} = Image.Plug.init(otp_app: :image_plug)
    end

    test "init/1 carries inline options as defaults and honours :key" do
      assert {:runtime, :image_plug, MyConfigKey, [on_error: :status_text]} =
               Image.Plug.init(otp_app: :image_plug, key: MyConfigKey, on_error: :status_text)
    end

    test "call/2 reads the configuration from the application env on first request" do
      key = RuntimeConfigRoundTrip

      Application.put_env(:image_plug, key,
        provider: {Image.Plug.Provider.Cloudflare, []},
        source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
        on_error: :status_text
      )

      on_exit(fn ->
        Application.delete_env(:image_plug, key)
        :persistent_term.erase({Image.Plug, :runtime_options, :image_plug, key, []})
      end)

      runtime = Image.Plug.init(otp_app: :image_plug, key: key)

      conn =
        conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
        |> Image.Plug.call(runtime)

      assert conn.status == 200
      assert binary_part(conn.resp_body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test "application-env config overrides inline defaults per key" do
      key = RuntimeConfigOverride

      defaults = [
        provider: {Image.Plug.Provider.Cloudflare, []},
        source_resolver: {Image.Plug.SourceResolver.File, root: "/nonexistent"},
        on_error: :status_text
      ]

      # The runtime config supplies only a (valid) source resolver, which must
      # override the inline default pointing at a nonexistent root.
      Application.put_env(:image_plug, key,
        source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures}
      )

      on_exit(fn ->
        Application.delete_env(:image_plug, key)
        :persistent_term.erase({Image.Plug, :runtime_options, :image_plug, key, defaults})
      end)

      runtime = Image.Plug.init([otp_app: :image_plug, key: key] ++ defaults)

      conn =
        conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
        |> Image.Plug.call(runtime)

      assert conn.status == 200
    end

    test "an invalid runtime configuration raises on the first request" do
      key = RuntimeConfigInvalid

      # :provider is missing, so Options.new! raises when resolved.
      Application.put_env(:image_plug, key,
        source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures}
      )

      on_exit(fn ->
        Application.delete_env(:image_plug, key)
        :persistent_term.erase({Image.Plug, :runtime_options, :image_plug, key, []})
      end)

      runtime = Image.Plug.init(otp_app: :image_plug, key: key)

      assert_raise ArgumentError, ~r/required option :provider/, fn ->
        Image.Plug.call(conn(:get, "/cdn-cgi/image/width=100/sample.jpg"), runtime)
      end
    end
  end

  describe "end-to-end round trip" do
    test "transforms a JPEG fixture and streams it back as a chunked WebP" do
      options = build_options()

      conn =
        conn(:get, "/cdn-cgi/image/width=200,fit=cover,format=webp/sample.jpg")
        |> Image.Plug.call(options)

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/webp; charset=utf-8"]
      assert conn.state == :chunked

      # The chunked body is collected by Plug.Test into resp_body for
      # introspection.
      body = conn.resp_body
      assert byte_size(body) > 0
      assert binary_part(body, 0, 4) == "RIFF"
    end

    test "streams a JPEG output by default for format=jpeg" do
      options = build_options()

      conn =
        conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
        |> Image.Plug.call(options)

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
      assert binary_part(conn.resp_body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test "width=auto resolves to the source width and round-trips" do
      options = build_options()

      conn =
        conn(:get, "/cdn-cgi/image/width=auto,format=jpeg/sample.jpg")
        |> Image.Plug.call(options)

      assert conn.status == 200
      assert binary_part(conn.resp_body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test "missing source file responds with 404 :source_not_found" do
      options = build_options()

      conn =
        conn(:get, "/cdn-cgi/image/width=200/missing.jpg")
        |> Image.Plug.call(options)

      assert conn.status == 404
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") == ["source_not_found"]
    end

    test "a non-image URL passes through untouched and un-halted" do
      options = build_options()

      conn =
        conn(:get, "/some/wrong/path.jpg")
        |> Image.Plug.call(options)

      # The plug does not recognise the URL as its own, so it leaves the
      # conn alone for the host application's remaining plugs.
      refute conn.halted
      assert conn.state == :unset
      assert conn.status == nil
    end

    test "a malformed cdn-cgi URL responds with 400 :malformed_url" do
      options = build_options()

      conn =
        conn(:get, "/cdn-cgi/image/width=100")
        |> Image.Plug.call(options)

      assert conn.status == 400
      assert conn.halted
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") == ["malformed_url"]
    end

    test "unknown option responds with 400 :unknown_option" do
      options = build_options()

      conn =
        conn(:get, "/cdn-cgi/image/wat=1/sample.jpg")
        |> Image.Plug.call(options)

      assert conn.status == 400
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") == ["unknown_option"]
    end

    test "hosted URL form with an unknown variant returns 404 :variant_not_found" do
      options =
        build_options(provider: {Image.Plug.Provider.Cloudflare, hosted_account_hash: "acct"})

      conn =
        conn(:get, "/acct/img/this-variant-does-not-exist")
        |> Image.Plug.call(options)

      assert conn.status == 404
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") == ["variant_not_found"]
    end

    test "hosted URL form with an options tail round-trips" do
      options =
        build_options(provider: {Image.Plug.Provider.Cloudflare, hosted_account_hash: "acct"})

      conn =
        conn(:get, "/acct/sample.jpg/width=100,format=jpeg")
        |> Image.Plug.call(options)

      # Hosted source -> :hosted kind -> Composite resolver dispatches
      # to the host's :hosted resolver, which we haven't configured.
      # So we expect a configuration error rather than a 200.
      assert conn.status == 400
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") == ["invalid_option"]
    end
  end

  describe "variant resolution (M4)" do
    defmodule HostedFileResolver do
      # Tiny test-only resolver: treats `{_account, image_id}` as a
      # filename under the configured fixtures root and delegates to
      # `Image.Plug.SourceResolver.File`.
      @behaviour Image.Plug.SourceResolver

      @impl true
      def load(%Image.Plug.Source{kind: :hosted, ref: {_account, image_id}}, options) do
        {:ok, path_source} = Image.Plug.Source.path("/" <> image_id)
        Image.Plug.SourceResolver.File.load(path_source, options)
      end
    end

    setup do
      table = :"plugvariant_#{System.unique_integer([:positive])}"
      name = :"#{table}_server"

      {:ok, pid} =
        Image.Plug.VariantStore.ETS.Server.start_link(name: name, table: table, seed: [])

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      Image.Plug.put_variant(
        "thumbnail",
        "width=100,height=100,fit=cover,format=jpeg",
        table: table,
        server: name
      )

      plug_options =
        Image.Plug.init(
          provider: {Image.Plug.Provider.Cloudflare, hosted_account_hash: "acct"},
          source_resolver:
            {Image.Plug.SourceResolver.Composite,
             file: [root: @fixtures], hosted: {HostedFileResolver, root: @fixtures}},
          variant_store: {Image.Plug.VariantStore.ETS, [table: table, server: name]},
          on_error: :status_text
        )

      %{plug_options: plug_options}
    end

    test "hosted URL with a known variant returns the transformed image", %{
      plug_options: plug_options
    } do
      conn =
        conn(:get, "/acct/sample.jpg/thumbnail")
        |> Image.Plug.call(plug_options)

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
      assert binary_part(conn.resp_body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test "the implicit `public` variant is always resolvable", %{plug_options: plug_options} do
      # `public` is seeded by the GenServer and is the empty pipeline.
      # Encoder defaults to :auto -> JPEG (no Accept header in the
      # test conn).
      conn =
        conn(:get, "/acct/sample.jpg")
        |> Image.Plug.call(plug_options)

      assert conn.status == 200
    end

    test "unknown variant returns 404 :variant_not_found", %{plug_options: plug_options} do
      conn =
        conn(:get, "/acct/sample.jpg/this-does-not-exist")
        |> Image.Plug.call(plug_options)

      assert conn.status == 404
    end
  end

  describe "on_error policy (M6)" do
    test ":render_error_image returns a 200 PNG placeholder for malformed URLs" do
      options = build_options(on_error: :render_error_image)

      conn =
        conn(:get, "/cdn-cgi/image/width=100")
        |> Image.Plug.call(options)

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") == ["malformed_url"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      # PNG magic bytes.
      assert binary_part(conn.resp_body, 0, 4) == <<0x89, "PNG">>
    end

    test ":fallback_to_source streams the source when interpreter fails after load" do
      # Construct a request that successfully loads the source but
      # fails during interpretation. The Segment op is implemented
      # as a no-op, so we need a different op. Use Resize with
      # zero-size to force a libvips failure (target=0 is rejected).
      # In practice the parser blocks width=0; use a Pipeline with
      # a Draw op that has no resolver.
      options =
        build_options(
          on_error: :fallback_to_source,
          # Override the source_resolver with a stub that returns an
          # image plus content_type, then uses the file resolver
          # under the hood.
          source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures}
        )

      # Build a URL that loads sample.jpg then runs a Draw op (no
      # resolver -> :invalid_option mid-pipeline).
      inner =
        URI.encode("url(https://example.com/wm.png)", &URI.char_unreserved?/1)

      conn =
        conn(:get, "/cdn-cgi/image/draw=#{inner},format=jpeg/sample.jpg")
        |> Image.Plug.call(options)

      # Source loaded successfully, then Draw failed because the
      # source resolver doesn't handle :url. Fallback streams the
      # original source as JPEG.
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") != []
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert binary_part(conn.resp_body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test ":fallback_to_source falls through to status when source load fails" do
      options = build_options(on_error: :fallback_to_source)

      conn =
        conn(:get, "/cdn-cgi/image/width=200/missing.jpg")
        |> Image.Plug.call(options)

      # Source never loaded -> nothing to fall back to.
      assert conn.status == 404
    end

    test "{:status, code} responds with the given status for any error" do
      options = build_options(on_error: {:status, 500})

      conn =
        conn(:get, "/cdn-cgi/image/wat=1/sample.jpg")
        |> Image.Plug.call(options)

      assert conn.status == 500
    end
  end

  describe "cache headers (M6)" do
    test "successful response carries ETag, Cache-Control, and Vary" do
      options = build_options()

      conn =
        conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
        |> Image.Plug.call(options)

      assert conn.status == 200
      assert [<<_::binary>>] = Plug.Conn.get_resp_header(conn, "etag")
      assert [_] = Plug.Conn.get_resp_header(conn, "cache-control")
      assert ["Accept"] = Plug.Conn.get_resp_header(conn, "vary")
    end

    test "If-None-Match matching ETag returns 304" do
      options = build_options()

      first =
        conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
        |> Image.Plug.call(options)

      [etag] = Plug.Conn.get_resp_header(first, "etag")

      second =
        conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
        |> Plug.Conn.put_req_header("if-none-match", etag)
        |> Image.Plug.call(options)

      assert second.status == 304
      assert second.resp_body == ""
    end

    test "ETag is stable across option ordering" do
      options = build_options()

      conn_a =
        conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
        |> Image.Plug.call(options)

      conn_b =
        conn(:get, "/cdn-cgi/image/format=jpeg,width=100/sample.jpg")
        |> Image.Plug.call(options)

      [etag_a] = Plug.Conn.get_resp_header(conn_a, "etag")
      [etag_b] = Plug.Conn.get_resp_header(conn_b, "etag")
      assert etag_a == etag_b
    end
  end

  describe "Draw / overlay (M5)" do
    defmodule WatermarkResolver do
      @behaviour Image.Plug.SourceResolver

      @impl true
      def load(%Image.Plug.Source{kind: :url}, options) do
        # Stub: the test passes a fixture path via the resolver
        # options instead of doing a real HTTP fetch.
        path = Keyword.fetch!(options, :fixture)
        {:ok, image} = Image.open(path)

        meta = %{content_type: "image/png", etag_seed: path}
        {:ok, image, meta}
      end

      def load(%Image.Plug.Source{kind: :path} = source, options) do
        Image.Plug.SourceResolver.File.load(source, options)
      end
    end

    test "URL with draw=url(...) composes the overlay" do
      watermark_path = Path.expand("../../fixtures/images/watermark.png", __DIR__)

      plug_options =
        Image.Plug.init(
          provider: {Image.Plug.Provider.Cloudflare, []},
          source_resolver:
            {Image.Plug.SourceResolver.Composite,
             file: [root: @fixtures], http: [fixture: watermark_path]}
        )

      # Replace the http resolver with our local stub for this test.
      plug_options = %{
        plug_options
        | source_resolver: WatermarkResolver,
          source_resolver_options: [root: @fixtures, fixture: watermark_path]
      }

      # Inner URLs and `;` need percent-encoding because the path
      # otherwise gets split by `Plug.Conn` on `/` and `;`.
      inner =
        URI.encode(
          "url(https://example.com/wm.png);right=10;bottom=10",
          &URI.char_unreserved?/1
        )

      url = "/cdn-cgi/image/width=400,format=jpeg,draw=#{inner}/sample.jpg"

      conn = conn(:get, url) |> Image.Plug.call(plug_options)

      assert conn.status == 200
      assert binary_part(conn.resp_body, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end
  end

  describe "mounting in a Phoenix endpoint pipeline" do
    # Simulates `plug Image.Plug` followed by another plug in an
    # endpoint: the downstream plug only runs (and sends) when
    # Image.Plug passed the request through un-halted. Before the
    # passthrough/halt fix, a non-image request errored and a served
    # image left the conn un-halted, so the downstream send raised
    # `Plug.Conn.AlreadySentError`.
    defp run_pipeline(conn, options) do
      conn = Image.Plug.call(conn, options)

      if conn.halted do
        conn
      else
        Plug.Conn.send_resp(conn, 204, "downstream")
      end
    end

    test "a non-image request flows to the downstream plug" do
      conn = run_pipeline(conn(:get, "/"), build_options())

      assert conn.status == 204
      assert conn.resp_body == "downstream"
    end

    test "an unrelated nested path flows to the downstream plug" do
      conn = run_pipeline(conn(:get, "/users/42/edit"), build_options())

      assert conn.status == 204
    end

    test "a served image halts before the downstream plug" do
      conn =
        run_pipeline(
          conn(:get, "/cdn-cgi/image/width=50,format=jpeg/sample.jpg"),
          build_options()
        )

      assert conn.halted
      assert conn.status == 200
      refute conn.resp_body == "downstream"
    end

    test "a malformed image request errors and halts, no downstream send" do
      conn = run_pipeline(conn(:get, "/cdn-cgi/image/width=50"), build_options())

      assert conn.halted
      assert conn.status == 400
      assert Plug.Conn.get_resp_header(conn, "x-image-plug-error") == ["malformed_url"]
    end

    test "with a mount prefix, only requests under it are claimed" do
      options = build_options(provider: {Image.Plug.Provider.Cloudflare, mount: "/img"})

      passthrough = run_pipeline(conn(:get, "/dashboard"), options)
      assert passthrough.status == 204

      served =
        run_pipeline(conn(:get, "/img/cdn-cgi/image/width=50,format=jpeg/sample.jpg"), options)

      assert served.halted
      assert served.status == 200
    end
  end
end
