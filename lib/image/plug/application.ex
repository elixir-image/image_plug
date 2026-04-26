defmodule Image.Plug.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Image.Plug.Capabilities.probe()

    seeds = Application.get_env(:image_plug, :variants, [])

    children = [
      {Image.Plug.VariantStore.ETS.Server, [seed: seeds]}
    ]

    opts = [strategy: :one_for_one, name: Image.Plug.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
