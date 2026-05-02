defmodule Image.Plug.Pipeline.Ops.Fade do
  @moduledoc """
  Alpha-gradient fade-out on one or more edges. `:edges` is
  `:all` or a list drawn from `:top`, `:bottom`, `:left`,
  `:right`. `:length` is either an integer pixel count or a
  float fraction of the relevant dimension. Maps to
  Cloudinary's `e_fade[:N]` (`N` interpreted as a percentage).
  """

  @type edge :: :top | :bottom | :left | :right
  @type t :: %__MODULE__{
          edges: [edge()] | :all,
          length: pos_integer() | float()
        }

  defstruct edges: [:bottom],
            length: 0.2
end
