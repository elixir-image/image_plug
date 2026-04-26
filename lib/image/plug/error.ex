defmodule Image.Plug.Error do
  @moduledoc """
  Tagged error type returned by every public function in `Image.Plug`.

  An error carries a stable `:tag` (an atom suitable for pattern matching
  and for mapping to HTTP status codes), a human-readable `:message`,
  and optional `:details` for diagnostic context.

  Errors are returned as `{:error, %Image.Plug.Error{}}`. They are not
  raised — `try/rescue` is reserved for true system boundaries per the
  project's code style.
  """

  @typedoc """
  A stable error tag. The set is open; callers should match the tags
  documented for the function they call and treat unknown tags as `:internal`.
  """
  @type tag ::
          :unknown_option
          | :invalid_option
          | :malformed_url
          | :variant_not_found
          | :variant_already_exists
          | :source_not_found
          | :source_fetch_error
          | :source_too_large
          | :unsupported_source_format
          | :unsupported_output_format
          | :unsupported_option
          | :output_too_large
          | :request_timeout
          | :pipeline_failed
          | :signature_required
          | :invalid_signature
          | :signature_expired
          | :not_implemented
          | :internal

  @type t :: %__MODULE__{
          tag: tag(),
          message: String.t(),
          details: map()
        }

  @enforce_keys [:tag, :message]
  defstruct tag: :internal, message: "", details: %{}

  @doc """
  Builds an error struct.

  ### Arguments

  * `tag` is an atom from `t:tag/0` describing the error class.

  * `message` is a human-readable description of the failure.

  ### Options

  * `:details` is a map of extra diagnostic context. Defaults to `%{}`.

  ### Returns

  * An `Image.Plug.Error` struct.

  ### Examples

      iex> error = Image.Plug.Error.new(:unknown_option, "no such option", details: %{key: "wat"})
      iex> error.tag
      :unknown_option
      iex> error.details
      %{key: "wat"}

  """
  @spec new(tag(), String.t(), keyword()) :: t()
  def new(tag, message, options \\ []) when is_atom(tag) and is_binary(message) do
    %__MODULE__{
      tag: tag,
      message: message,
      details: Keyword.get(options, :details, %{})
    }
  end

  @doc """
  Maps an error tag to a default HTTP status code.

  ### Arguments

  * `error_or_tag` is either an `Image.Plug.Error` struct or an
    error tag atom.

  ### Returns

  * An integer HTTP status code.

  ### Examples

      iex> Image.Plug.Error.status(:variant_not_found)
      404

      iex> Image.Plug.Error.status(Image.Plug.Error.new(:invalid_option, "bad"))
      400

      iex> Image.Plug.Error.status(:internal)
      500

  """
  @spec status(t() | tag()) :: 100..599
  def status(%__MODULE__{tag: tag}), do: status(tag)

  def status(:unknown_option), do: 400
  def status(:invalid_option), do: 400
  def status(:malformed_url), do: 400
  def status(:variant_not_found), do: 404
  def status(:variant_already_exists), do: 409
  def status(:source_not_found), do: 404
  def status(:source_fetch_error), do: 502
  def status(:source_too_large), do: 413
  def status(:unsupported_source_format), do: 415
  def status(:unsupported_output_format), do: 415
  def status(:unsupported_option), do: 400
  def status(:output_too_large), do: 413
  def status(:request_timeout), do: 504
  def status(:pipeline_failed), do: 500
  def status(:signature_required), do: 401
  def status(:invalid_signature), do: 401
  def status(:signature_expired), do: 401
  def status(:not_implemented), do: 501
  def status(:internal), do: 500
  def status(_other), do: 500
end
