defmodule Image.Plug.Capabilities do
  @moduledoc """
  Probes the local libvips build for optional encoder capabilities.

  Run once at application boot. Results are cached in
  `:persistent_term` so per-request reads are free.

  Currently probes AVIF, JP2, and TIFF write support. Adding a
  probe for another capability is one new clause in `probe/0` and
  one new accessor.
  """

  require Logger

  @probe_key {__MODULE__, :avif_write?}

  @doc """
  Performs every capability probe and caches the results.

  Idempotent: calling `probe/0` twice in the same VM lifetime returns
  the same booleans without re-probing.

  ### Returns

  * `:ok`.

  """
  @spec probe() :: :ok
  def probe do
    case :persistent_term.get(@probe_key, :unprobed) do
      :unprobed ->
        avif? = probe_avif_write()
        :persistent_term.put(@probe_key, avif?)

        unless avif? do
          Logger.warning(
            "image_plug: libvips lacks AVIF write support — `format=avif` " <>
              "requests will be served as WebP and tagged with " <>
              "`x-image-plug-format-fallback: avif->webp`."
          )
        end

        :ok

      _cached ->
        :ok
    end
  end

  @doc """
  Returns whether the local libvips can encode AVIF.

  Falls back to a one-off probe if `probe/0` (in this module) has
  not been called — useful in tests that exercise the encoder
  without booting the application.

  ### Returns

  * `true` if libvips can write AVIF.

  * `false` otherwise.

  ### Examples

      iex> is_boolean(Image.Plug.Capabilities.avif_write?())
      true

  """
  @spec avif_write?() :: boolean()
  def avif_write? do
    case :persistent_term.get(@probe_key, :unprobed) do
      :unprobed ->
        result = probe_avif_write()
        :persistent_term.put(@probe_key, result)
        result

      result when is_boolean(result) ->
        result
    end
  end

  defp probe_avif_write, do: probe_format_write(".avif")

  @doc """
  Returns whether the local libvips can encode TIFF.

  Required by IIIF Image API 3.0 Compliance Level 2 deployments
  that promise TIFF support.

  ### Returns

  * `true` if libvips can write TIFF.

  * `false` otherwise.

  """
  @spec tiff_write?() :: boolean()
  def tiff_write?, do: cached_probe({__MODULE__, :tiff_write?}, ".tif")

  @doc """
  Returns whether the local libvips can encode JPEG 2000 (JP2).

  Required by IIIF Image API 3.0 Compliance Level 2 deployments
  that promise JP2 support. Available only when libvips was built
  with `libopenjp2`.

  ### Returns

  * `true` if libvips can write JP2.

  * `false` otherwise.

  """
  @spec jp2_write?() :: boolean()
  def jp2_write?, do: cached_probe({__MODULE__, :jp2_write?}, ".jp2")

  defp cached_probe(key, suffix) do
    case :persistent_term.get(key, :unprobed) do
      :unprobed ->
        result = probe_format_write(suffix)
        :persistent_term.put(key, result)
        result

      result when is_boolean(result) ->
        result
    end
  end

  defp probe_format_write(suffix) do
    case Image.new(1, 1, color: [0, 0, 0]) do
      {:ok, image} ->
        case Image.write(image, :memory, suffix: suffix, quality: 50) do
          {:ok, _bytes} -> true
          {:error, _reason} -> false
        end

      {:error, _reason} ->
        false
    end
  rescue
    # `Image.write/3` can raise (e.g. via `stream!/2`) for some
    # invalid suffix configurations on builds without the encoder.
    _ -> false
  end
end
