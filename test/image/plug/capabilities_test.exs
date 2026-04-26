defmodule Image.Plug.CapabilitiesTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Capabilities

  test "avif_write?/0 returns a boolean (cached after first call)" do
    result_1 = Image.Plug.Capabilities.avif_write?()
    result_2 = Image.Plug.Capabilities.avif_write?()

    assert is_boolean(result_1)
    assert result_1 == result_2
  end

  test "probe/0 is idempotent" do
    assert :ok = Image.Plug.Capabilities.probe()
    assert :ok = Image.Plug.Capabilities.probe()
  end
end
