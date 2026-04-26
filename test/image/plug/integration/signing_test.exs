defmodule Image.Plug.Integration.SigningTest do
  @moduledoc """
  End-to-end signing: stand up a Bandit with `:signing` configured,
  fire signed/unsigned/tampered requests, assert wire behaviour.
  """

  @fixtures Path.expand("../../../fixtures/images", __DIR__)
  @keys ["integration-test-secret"]

  use ExUnit.Case, async: false

  defp start_plug(signing_config) do
    {:ok, server_pid} =
      Bandit.start_link(
        plug:
          {Image.Plug,
           [
             provider: {Image.Plug.Provider.Cloudflare, []},
             source_resolver: {Image.Plug.SourceResolver.File, root: @fixtures},
             on_error: :status_text,
             signing: signing_config
           ]},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :shutdown)
    end)

    "http://127.0.0.1:#{port}"
  end

  describe "signing not configured (signing: nil)" do
    test "unsigned URL returns 200" do
      base_url = start_plug(nil)

      {:ok, response} =
        Req.get(base_url <> "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg")

      assert response.status == 200
    end

    test "URL with a stray ?sig= still works (verification not active)" do
      base_url = start_plug(nil)

      {:ok, response} =
        Req.get(base_url <> "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg?sig=garbage")

      assert response.status == 200
    end
  end

  describe "signing required" do
    test "unsigned URL returns 401 :signature_required" do
      base_url = start_plug(%{keys: @keys, required?: true})

      {:ok, response} =
        Req.get(base_url <> "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg")

      assert response.status == 401
      assert response.headers["x-image-plug-error"] == ["signature_required"]
    end

    test "validly-signed URL returns 200" do
      base_url = start_plug(%{keys: @keys, required?: true})
      path = "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg"
      signed = Image.Plug.Signing.sign(path, @keys)

      {:ok, response} = Req.get(base_url <> signed)
      assert response.status == 200
    end

    test "tampered signature returns 401 :invalid_signature" do
      base_url = start_plug(%{keys: @keys, required?: true})
      path = "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg"
      signed = Image.Plug.Signing.sign(path, @keys)
      tampered = String.replace(signed, "?sig=", "?sig=00000000")

      {:ok, response} = Req.get(base_url <> tampered)

      assert response.status == 401
      assert response.headers["x-image-plug-error"] == ["invalid_signature"]
    end

    test "expired signature returns 401 :signature_expired" do
      base_url = start_plug(%{keys: @keys, required?: true})
      path = "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg"
      past = System.system_time(:second) - 10
      signed = Image.Plug.Signing.sign(path, @keys, expires_at: past)

      {:ok, response} = Req.get(base_url <> signed)

      assert response.status == 401
      assert response.headers["x-image-plug-error"] == ["signature_expired"]
    end
  end

  describe "signing optional (defense in depth)" do
    test "unsigned URL still returns 200" do
      base_url = start_plug(%{keys: @keys, required?: false})

      {:ok, response} =
        Req.get(base_url <> "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg")

      assert response.status == 200
    end

    test "but a tampered signature is still rejected" do
      base_url = start_plug(%{keys: @keys, required?: false})
      path = "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg"
      signed = Image.Plug.Signing.sign(path, @keys)
      tampered = String.replace(signed, "?sig=", "?sig=ffff")

      {:ok, response} = Req.get(base_url <> tampered)
      assert response.status == 401
    end
  end

  describe "key rotation" do
    test "URL signed with an old key still verifies during rotation" do
      base_url = start_plug(%{keys: ["new-key", "old-key"], required?: true})
      path = "/cdn-cgi/image/width=200,format=jpeg/portrait.jpg"
      signed_with_old = Image.Plug.Signing.sign(path, ["old-key"])

      {:ok, response} = Req.get(base_url <> signed_with_old)
      assert response.status == 200
    end
  end
end
