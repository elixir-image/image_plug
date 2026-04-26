defmodule Image.Plug.VersionTest do
  use ExUnit.Case, async: true
  doctest Image.Plug

  test "version/0 is a non-empty string" do
    assert is_binary(Image.Plug.version())
    assert byte_size(Image.Plug.version()) > 0
  end

  test "default_telemetry_prefix/0 returns [:image_plug]" do
    assert Image.Plug.default_telemetry_prefix() == [:image_plug]
  end
end
