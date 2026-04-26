defmodule Image.Plug.Pipeline do
  @moduledoc """
  The canonical, provider-neutral image-processing pipeline.

  A pipeline is an ordered list of typed operation structs (under
  `Image.Plug.Pipeline.Ops.*`) plus pipeline-wide settings: the
  output format, an error policy, and a debug breadcrumb identifying
  the provider that produced it.

  Pipelines are pure data. Behaviour lives in
  `Image.Plug.Pipeline.Interpreter` (executes ops),
  `Image.Plug.Pipeline.Encoder` (serialises the result), and
  `Image.Plug.Pipeline.Normaliser` (reorders, folds, validates).
  """

  alias Image.Plug.Pipeline.Ops

  @type op ::
          Ops.Rotate.t()
          | Ops.Trim.t()
          | Ops.Flip.t()
          | Ops.Resize.t()
          | Ops.Background.t()
          | Ops.Adjust.t()
          | Ops.Sharpen.t()
          | Ops.Blur.t()
          | Ops.Border.t()
          | Ops.Draw.t()
          | Ops.Segment.t()

  @type on_error :: :auto | :render_error_image | :fallback_to_source | :raise | {:status, 100..599}

  @type t :: %__MODULE__{
          ops: [op()],
          output: Ops.Format.t(),
          on_error: on_error(),
          provider: nil | module()
        }

  defstruct ops: [],
            output: %Ops.Format{},
            on_error: :auto,
            provider: nil

  @doc """
  Builds a new, empty pipeline.

  ### Options

  * `:output` is an `Image.Plug.Pipeline.Ops.Format` struct describing
    the encoder configuration. Defaults to `%Ops.Format{}` (auto format,
    quality 85, copyright-only metadata).

  * `:on_error` is the error policy. Defaults to `:auto` — see
    `Image.Plug` for selection semantics.

  * `:provider` is an optional debug breadcrumb identifying the provider
    module that produced the pipeline.

  ### Returns

  * An empty `Image.Plug.Pipeline` struct.

  ### Examples

      iex> p = Image.Plug.Pipeline.new()
      iex> p.ops
      []
      iex> p.output.type
      :auto

  """
  @spec new(keyword()) :: t()
  def new(options \\ []) when is_list(options) do
    %__MODULE__{
      ops: [],
      output: Keyword.get(options, :output, %Ops.Format{}),
      on_error: Keyword.get(options, :on_error, :auto),
      provider: Keyword.get(options, :provider)
    }
  end

  @doc """
  Appends an operation to a pipeline.

  ### Arguments

  * `pipeline` is an `Image.Plug.Pipeline` struct.

  * `op` is any operation struct under `Image.Plug.Pipeline.Ops.*`.

  ### Returns

  * The pipeline with `op` appended to `:ops`.

  ### Examples

      iex> alias Image.Plug.Pipeline
      iex> alias Image.Plug.Pipeline.Ops.Rotate
      iex> p = Pipeline.append(Pipeline.new(), %Rotate{angle: 90})
      iex> length(p.ops)
      1

  """
  @spec append(t(), op()) :: t()
  def append(%__MODULE__{} = pipeline, op) when is_struct(op) do
    %{pipeline | ops: pipeline.ops ++ [op]}
  end

  @doc """
  Replaces the pipeline's output (`Ops.Format`) struct.

  ### Arguments

  * `pipeline` is an `Image.Plug.Pipeline` struct.

  * `format` is an `Image.Plug.Pipeline.Ops.Format` struct.

  ### Returns

  * The pipeline with `:output` replaced.

  ### Examples

      iex> alias Image.Plug.Pipeline
      iex> alias Image.Plug.Pipeline.Ops.Format
      iex> p = Pipeline.put_output(Pipeline.new(), %Format{type: :webp, quality: 80})
      iex> p.output.type
      :webp

  """
  @spec put_output(t(), Ops.Format.t()) :: t()
  def put_output(%__MODULE__{} = pipeline, %Ops.Format{} = format) do
    %{pipeline | output: format}
  end
end
