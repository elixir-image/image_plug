defmodule Image.Plug.Admin do
  @moduledoc """
  HTTP admin surface for variant CRUD.

  Mount this plug under whatever path your host exposes (the admin
  routes are intentionally relative — no baked-in prefix).

  | Method   | Path     | Action |
  | -------- | -------- | ------ |
  | `GET`    | `/`      | List all variants. |
  | `GET`    | `/:name` | Fetch one variant. |
  | `POST`   | `/`      | Create a variant. 409 on name conflict. |
  | `PUT`    | `/:name` | Upsert a variant. |
  | `PATCH`  | `/:name` | Partial update of an existing variant. |
  | `DELETE` | `/:name` | Delete a variant. |

  Request bodies use the canonical variant JSON shape:

      {
        "name": "thumbnail",
        "options": "width=200,height=200,fit=cover,format=webp",
        "metadata": {"description": "card thumbnail"},
        "never_require_signed_urls": false
      }

  `options` is a provider-specific options string parsed by the
  configured provider (Cloudflare by default).

  ### Configuration

  * `:provider` — module used to parse the `options` string.
    Defaults to `Image.Plug.Provider.Cloudflare`.

  * `:variant_store` — `{module, options}` tuple identifying the
    variant store. Defaults to `{Image.Plug.VariantStore.ETS, []}`.

  ### Authentication

  This plug does **not** authenticate or authorise requests. Wrap it
  in your host's auth pipeline (e.g. a `:basic_auth` plug or a
  Phoenix `:require_admin` pipeline) before exposing it publicly.
  """

  @behaviour Plug

  alias Image.Plug.{Error, Pipeline, Variant}

  require Logger

  @impl Plug
  def init(options) when is_list(options) do
    %{
      provider: Keyword.get(options, :provider, Image.Plug.Provider.Cloudflare),
      store:
        Keyword.get(options, :variant_store, {Image.Plug.VariantStore.ETS, []})
        |> normalise_store()
    }
  end

  defp normalise_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalise_store(module) when is_atom(module), do: {module, []}

  @impl Plug
  def call(%Plug.Conn{} = conn, %{} = config) do
    case route(conn) do
      {:list} -> handle_list(conn, config)
      {:get, name} -> handle_get(conn, config, name)
      {:create} -> handle_create(conn, config)
      {:upsert, name} -> handle_upsert(conn, config, name)
      {:patch, name} -> handle_patch(conn, config, name)
      {:delete, name} -> handle_delete(conn, config, name)
      :unknown -> respond_error(conn, Error.new(:malformed_url, "no admin route matched"))
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: []}), do: {:list}
  defp route(%Plug.Conn{method: "GET", path_info: [name]}), do: {:get, name}
  defp route(%Plug.Conn{method: "POST", path_info: []}), do: {:create}
  defp route(%Plug.Conn{method: "PUT", path_info: [name]}), do: {:upsert, name}
  defp route(%Plug.Conn{method: "PATCH", path_info: [name]}), do: {:patch, name}
  defp route(%Plug.Conn{method: "DELETE", path_info: [name]}), do: {:delete, name}
  defp route(_conn), do: :unknown

  # ---------- handlers ----------

  defp handle_list(conn, config) do
    {store_module, store_options} = config.store
    {:ok, variants} = store_module.list(store_options)
    body = %{"result" => Enum.map(variants, &variant_to_json/1)}
    json_response(conn, 200, body)
  end

  defp handle_get(conn, config, name) do
    {store_module, store_options} = config.store

    case store_module.get(name, store_options) do
      {:ok, variant} -> json_response(conn, 200, variant_to_json(variant))
      {:error, :not_found} -> respond_error(conn, Error.new(:variant_not_found, "no such variant"))
    end
  end

  defp handle_create(conn, config) do
    {store_module, store_options} = config.store

    with {:ok, params} <- read_json(conn),
         {:ok, name} <- fetch_name(params),
         {:error, :not_found} <- store_module.get(name, store_options),
         {:ok, variant} <- build_variant(name, params, config) do
      put_and_respond(conn, store_module, store_options, variant, 201)
    else
      {:ok, %Variant{}} ->
        respond_error(conn, Error.new(:variant_already_exists, "variant already exists"))

      {:error, %Error{} = error} ->
        respond_error(conn, error)
    end
  end

  defp handle_upsert(conn, config, name) do
    {store_module, store_options} = config.store

    with {:ok, params} <- read_json(conn),
         params = Map.put(params, "name", name),
         {:ok, variant} <- build_variant(name, params, config) do
      put_and_respond(conn, store_module, store_options, variant, 200)
    else
      {:error, %Error{} = error} -> respond_error(conn, error)
    end
  end

  defp handle_patch(conn, config, name) do
    {store_module, store_options} = config.store

    with {:ok, existing} <- store_module.get(name, store_options),
         {:ok, params} <- read_json(conn),
         {:ok, merged} <- merge_variant(existing, params, config) do
      put_and_respond(conn, store_module, store_options, merged, 200)
    else
      {:error, :not_found} ->
        respond_error(conn, Error.new(:variant_not_found, "no such variant"))

      {:error, %Error{} = error} ->
        respond_error(conn, error)
    end
  end

  defp handle_delete(conn, config, name) do
    {store_module, store_options} = config.store

    case store_module.delete(name, store_options) do
      :ok -> json_response(conn, 200, %{"result" => %{"deleted" => name}})
      {:error, :not_found} -> respond_error(conn, Error.new(:variant_not_found, "no such variant"))
    end
  end

  defp put_and_respond(conn, store_module, store_options, variant, status) do
    case store_module.put(variant, store_options) do
      {:ok, stored} -> json_response(conn, status, variant_to_json(stored))
      {:error, reason} -> respond_error(conn, Error.new(:internal, "store rejected variant", details: %{reason: inspect(reason)}))
    end
  end

  # ---------- variant <-> JSON ----------

  defp build_variant(name, params, config) do
    options_string = Map.get(params, "options", "")

    case parse_options(config.provider, options_string) do
      {:ok, pipeline} ->
        {:ok,
         %Variant{
           name: name,
           pipeline: pipeline,
           options: options_string,
           metadata: Map.get(params, "metadata", %{}) |> ensure_map(),
           never_require_signed_urls?: !!Map.get(params, "never_require_signed_urls", false)
         }}

      {:error, _} = error ->
        error
    end
  end

  defp merge_variant(%Variant{} = existing, params, config) do
    options_string = Map.get(params, "options", existing.options)

    with {:ok, pipeline} <- parse_options(config.provider, options_string || "") do
      {:ok,
       %Variant{
         existing
         | pipeline: pipeline,
           options: options_string,
           metadata: Map.get(params, "metadata", existing.metadata) |> ensure_map(),
           never_require_signed_urls?:
             case Map.fetch(params, "never_require_signed_urls") do
               {:ok, value} -> !!value
               :error -> existing.never_require_signed_urls?
             end
       }}
    end
  end

  defp parse_options(Image.Plug.Provider.Cloudflare, options_string) do
    Image.Plug.Provider.Cloudflare.Options.parse(options_string)
  end

  defp parse_options(provider, _options_string) do
    {:error,
     Error.new(:invalid_option,
       "no options-string parser registered for provider",
       details: %{provider: provider}
     )}
  end

  defp variant_to_json(%Variant{} = variant) do
    %{
      "name" => variant.name,
      "options" => variant.options,
      "metadata" => variant.metadata,
      "never_require_signed_urls" => variant.never_require_signed_urls?,
      "inserted_at" => datetime_to_iso(variant.inserted_at),
      "updated_at" => datetime_to_iso(variant.updated_at),
      "ops" => Enum.map(variant.pipeline.ops, &op_to_json/1),
      "output" => format_to_json(variant.pipeline.output)
    }
  end

  defp op_to_json(%struct{} = op) do
    %{
      "kind" => struct |> Module.split() |> List.last(),
      "fields" =>
        op
        |> Map.from_struct()
        |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), inspect_value(v)} end)
    }
  end

  defp format_to_json(%Pipeline.Ops.Format{} = format) do
    %{
      "type" => Atom.to_string(format.type),
      "quality" => format.quality,
      "metadata" => Atom.to_string(format.metadata),
      "anim" => format.anim?,
      "dpr" => format.dpr
    }
  end

  defp inspect_value(nil), do: nil
  defp inspect_value(value) when is_boolean(value), do: value
  defp inspect_value(value) when is_atom(value), do: Atom.to_string(value)
  defp inspect_value(value) when is_number(value), do: value
  defp inspect_value(value) when is_binary(value), do: value
  defp inspect_value(value), do: inspect(value)

  defp datetime_to_iso(nil), do: nil
  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_other), do: %{}

  # ---------- request body / response ----------

  defp read_json(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} ->
        case body do
          "" ->
            {:ok, %{}}

          binary ->
            try do
              {:ok, :json.decode(binary)}
            rescue
              _ -> {:error, Error.new(:invalid_option, "request body is not valid JSON")}
            end
        end

      {:error, _reason} ->
        {:error, Error.new(:invalid_option, "could not read request body")}
    end
  end

  defp fetch_name(params) do
    case Map.fetch(params, "name") do
      {:ok, name} when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, Error.new(:invalid_option, "request body must include a non-empty `name`")}
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, IO.iodata_to_binary(:json.encode(body)))
  end

  defp respond_error(conn, %Error{} = error) do
    Logger.warning(fn ->
      "image_server admin: tag=#{error.tag} message=#{error.message} details=#{inspect(error.details)}"
    end)

    body = %{"error" => Atom.to_string(error.tag), "message" => error.message}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("x-image-plug-error", to_string(error.tag))
    |> Plug.Conn.send_resp(Error.status(error), IO.iodata_to_binary(:json.encode(body)))
  end
end
