defmodule Image.Plug.TelemetryTest do
  use ExUnit.Case, async: false
  import Plug.Test

  @fixtures Path.expand("../../fixtures/images", __DIR__)

  defp build_options do
    Image.Plug.init(
      provider: {Image.Plug.Provider.Cloudflare, []},
      source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
      on_error: :status_text
    )
  end

  setup do
    handler_id = "test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:image_plug, :request, :start],
        [:image_plug, :request, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emits :start and :stop on a successful request" do
    options = build_options()

    conn(:get, "/cdn-cgi/image/width=100,format=jpeg/sample.jpg")
    |> Image.Plug.call(options)

    assert_received {:telemetry, [:image_plug, :request, :start], _measurements, start_meta}
    assert start_meta.request_path == "/cdn-cgi/image/width=100,format=jpeg/sample.jpg"

    assert_received {:telemetry, [:image_plug, :request, :stop], measurements, stop_meta}
    assert is_integer(measurements.duration)
    assert stop_meta.status == 200
    assert stop_meta.error_tag == nil
  end

  test ":stop carries the error tag for failures" do
    options = build_options()

    conn(:get, "/cdn-cgi/image/wat=1/sample.jpg")
    |> Image.Plug.call(options)

    assert_received {:telemetry, [:image_plug, :request, :stop], _measurements, stop_meta}
    assert stop_meta.error_tag == "unknown_option"
    assert stop_meta.status == 400
  end
end
