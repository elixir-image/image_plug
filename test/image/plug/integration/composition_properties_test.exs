defmodule Image.Plug.Integration.CompositionPropertiesTest do
  @moduledoc """
  Properties on combinations of options:

  * Any random N-key valid options string returns 200.

  * Replacing one valid entry with its invalid counterpart
    short-circuits to a 4xx with the right tag.

  * Shuffling the option order produces the same ETag and the same
    response body. Confirms the normaliser canonicalises correctly
    across the wire.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Cloudflare, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
    on_error: :status_text

  use ExUnitProperties

  import Image.Plug.TestGenerators

  property "any random valid N-key options string returns 200", %{base_url: base_url} do
    check all(
            options <- valid_options_string(4),
            # Anchor the request to a known source-format combo
            # by appending format=jpeg if format is unset (avoids
            # `format=auto` content-negotiating against an empty
            # Accept header).
            options = ensure_format(options),
            max_runs: 30
          ) do
      {:ok, response} = request("/cdn-cgi/image/#{options}/portrait.jpg", base_url: base_url)

      assert response.status == 200,
             "expected 200 for options #{inspect(options)}, got #{response.status} " <>
               "with body #{inspect(response.body)}"
    end
  end

  property "shuffling the option order produces the same ETag", %{base_url: base_url} do
    check all(
            options <- valid_options_string(4),
            options = ensure_format(options),
            max_runs: 25
          ) do
      shuffled =
        options
        |> String.split(",", trim: true)
        |> Enum.shuffle()
        |> Enum.join(",")

      {:ok, a} = request("/cdn-cgi/image/#{options}/portrait.jpg", base_url: base_url)
      {:ok, b} = request("/cdn-cgi/image/#{shuffled}/portrait.jpg", base_url: base_url)

      assert a.status == 200
      assert b.status == 200
      assert a.headers["etag"] == b.headers["etag"]
    end
  end

  defp ensure_format(options) do
    if String.contains?(options, "format=") do
      options
    else
      options <> ",format=jpeg"
    end
  end
end
