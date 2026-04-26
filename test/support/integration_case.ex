defmodule Image.Plug.IntegrationCase do
  @moduledoc """
  Test case template for HTTP-level integration tests of `Image.Plug`.

  Starts a Bandit server on a random free port in `setup_all`,
  mounts the plug with the configuration passed via `use`, and
  exposes a `request/2` helper that issues real HTTP requests via
  `Req`.

  ### Usage

      defmodule MyIntegrationTest do
        use Image.Plug.IntegrationCase,
          provider: {Image.Plug.Provider.Cloudflare, []},
          source_resolver: {Image.Plug.SourceResolver.File, root: "test/fixtures/images"},
          on_error: :status_text
      end

      test "fetches a thumbnail", %{base_url: base_url} do
        assert {:ok, response} = request("/cdn-cgi/image/width=200/portrait.jpg", base_url: base_url)
        assert response.status == 200
      end

  ### Reproducible property failures

  Property tests in suites that `use` this module accept the
  `STREAM_DATA_SEED` environment variable for reproduction:

      STREAM_DATA_SEED=12345 mix test path/to/property_test.exs

  ### `async`

  Test modules using this case must declare `async: false` because
  Bandit binds a real socket. The case sets `async: false` for you
  via `use ExUnit.Case`.
  """

  @doc false
  defmacro __using__(plug_options) do
    quote do
      use ExUnit.Case, async: false

      import Image.Plug.IntegrationCase, only: [request: 2, request: 1]

      @plug_options unquote(plug_options)

      setup_all do
        Image.Plug.IntegrationCase.start(@plug_options)
      end
    end
  end

  @doc """
  Starts a Bandit server on a random port mounted with the supplied
  `Image.Plug` configuration. Returns `%{base_url: ..., port: ...}`
  for use as a `setup_all` context.
  """
  @spec start(keyword()) :: {:ok, %{base_url: String.t(), port: non_neg_integer()}}
  def start(plug_options) do
    {:ok, server_pid} =
      Bandit.start_link(
        plug: {Image.Plug, plug_options},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    on_exit_stop(server_pid)

    {:ok, %{base_url: "http://127.0.0.1:#{port}", port: port, server: server_pid}}
  end

  @doc """
  Issues an HTTP GET against `path` (joined to the harness's
  `:base_url` taken from the test context). Returns `{:ok, %Req.Response{}}`
  on transport success.

  ### Options

  * `:base_url` — base URL string. Required when called outside an
    ExUnit context that supplies it via `setup_all`.

  * `:headers` — extra request headers, list of `{name, value}` tuples.

  * `:into` — Req's streaming option, e.g. `{:stream, fun}` to
    receive chunks as they arrive (useful for the chunked-transfer
    assertion in Phase B).

  """
  @spec request(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def request(path, options \\ []) do
    base_url = Keyword.fetch!(options, :base_url)
    url = base_url <> path

    Req.get(url,
      headers: Keyword.get(options, :headers, []),
      into: Keyword.get(options, :into),
      decode_body: false,
      retry: false,
      receive_timeout: 5_000
    )
  end

  defp on_exit_stop(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)
  end
end
