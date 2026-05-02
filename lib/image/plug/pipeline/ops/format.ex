defmodule Image.Plug.Pipeline.Ops.Format do
  @moduledoc """
  Output format / encoder configuration. Lives on the pipeline rather
  than in the op list — there is exactly one per pipeline.

  `:type` is the requested output format; `:auto` defers to content
  negotiation (Accept header) at encode time. The encoder may
  substitute a fallback format and add a header noting the substitution
  (currently only `:avif -> :webp` when libvips lacks AVIF support).
  """

  @type type ::
          :auto
          | :avif
          | :webp
          | :jpeg
          | :baseline_jpeg
          | :png
          | :json

  @type metadata :: :copyright | :keep | :none
  @type compression :: nil | :fast
  @type chroma_subsampling :: nil | :auto | :on | :off

  @type t :: %__MODULE__{
          type: type(),
          quality: 1..100,
          metadata: metadata(),
          anim?: boolean(),
          dpr: pos_integer(),
          compression: compression(),
          scq_quality: nil | 1..100,
          lossy: nil | boolean(),
          progressive: nil | boolean(),
          chroma_subsampling: chroma_subsampling()
        }

  defstruct type: :auto,
            quality: 85,
            metadata: :copyright,
            anim?: true,
            dpr: 1,
            compression: nil,
            scq_quality: nil,
            lossy: nil,
            progressive: nil,
            chroma_subsampling: nil
end
