defmodule Image.Plug.VariantTest do
  use ExUnit.Case, async: true

  alias Image.Plug.{Pipeline, Variant}

  test "build a variant with the required keys" do
    variant = %Variant{name: "thumbnail", pipeline: Pipeline.new()}

    assert variant.name == "thumbnail"
    assert variant.metadata == %{}
    assert variant.never_require_signed_urls? == false
  end

  test "missing required keys raises" do
    assert_raise ArgumentError, fn ->
      struct!(Variant, [])
    end
  end
end
