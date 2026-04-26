defmodule Image.Plug.ErrorTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Error

  alias Image.Plug.Error

  test "new/3 builds a struct with the given tag and message" do
    error = Error.new(:invalid_option, "no good", details: %{key: "x"})

    assert %Error{tag: :invalid_option, message: "no good", details: %{key: "x"}} = error
  end

  test "new/3 defaults details to an empty map" do
    assert %Error{details: %{}} = Error.new(:internal, "boom")
  end

  test "status/1 maps known tags to documented status codes" do
    assert Error.status(:unknown_option) == 400
    assert Error.status(:variant_not_found) == 404
    assert Error.status(:variant_already_exists) == 409
    assert Error.status(:source_too_large) == 413
    assert Error.status(:unsupported_output_format) == 415
    assert Error.status(:request_timeout) == 504
    assert Error.status(:source_fetch_error) == 502
    assert Error.status(:not_implemented) == 501
    assert Error.status(:internal) == 500
  end

  test "status/1 accepts an Error struct" do
    assert Error.status(Error.new(:variant_not_found, "x")) == 404
  end

  test "status/1 falls back to 500 for unknown tags" do
    assert Error.status(:nope_not_a_real_tag) == 500
  end
end
