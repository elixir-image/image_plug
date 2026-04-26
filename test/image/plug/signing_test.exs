defmodule Image.Plug.SigningTest do
  use ExUnit.Case, async: true
  doctest Image.Plug.Signing

  alias Image.Plug.{Error, Signing}

  @keys ["secret-1"]
  @rotation_keys ["new-key", "old-key"]

  describe "sign/3" do
    test "appends ?sig= to a path with no query string" do
      signed = Signing.sign("/foo.jpg", @keys)
      assert String.starts_with?(signed, "/foo.jpg?sig=")
    end

    test "appends &sig= to a path that already has a query string" do
      signed = Signing.sign("/foo.jpg?other=1", @keys)
      assert signed =~ "?other=1&sig="
    end

    test "appends ?exp= and ?sig= when :expires_at is set" do
      expiry = System.system_time(:second) + 3600
      signed = Signing.sign("/foo.jpg", @keys, expires_at: expiry)
      assert signed =~ "?exp=#{expiry}"
      assert signed =~ "&sig="
    end

    test "accepts a DateTime for :expires_at" do
      expiry = DateTime.from_unix!(2_000_000_000)
      signed = Signing.sign("/foo.jpg", @keys, expires_at: expiry)
      assert signed =~ "?exp=2000000000"
    end

    test "always uses the first key for signing" do
      a = Signing.sign("/foo.jpg", ["a", "b"])
      b = Signing.sign("/foo.jpg", ["a", "c"])
      # Same first key → same signature even though the rest of the
      # rotation list differs.
      assert a == b
    end
  end

  describe "verify/3 — unsigned" do
    test "passes when :required? is false (the default)" do
      assert :ok = Signing.verify("/foo.jpg", @keys)
    end

    test "errors :signature_required when :required? is true" do
      assert {:error, %Error{tag: :signature_required}} =
               Signing.verify("/foo.jpg", @keys, required?: true)
    end
  end

  describe "verify/3 — signed" do
    test "passes for a freshly-signed URL" do
      signed = Signing.sign("/foo.jpg", @keys)
      assert :ok = Signing.verify(signed, @keys, required?: true)
    end

    test "passes for a URL signed with any key in the rotation list" do
      signed_with_old = Signing.sign("/foo.jpg", ["old-key"])
      assert :ok = Signing.verify(signed_with_old, @rotation_keys)
    end

    test "errors :invalid_signature for a tampered signature" do
      signed = Signing.sign("/foo.jpg", @keys)
      tampered = String.replace(signed, "?sig=", "?sig=00000000")
      assert {:error, %Error{tag: :invalid_signature}} = Signing.verify(tampered, @keys)
    end

    test "errors :invalid_signature when the path is changed after signing" do
      signed = Signing.sign("/foo.jpg", @keys)
      tampered = String.replace(signed, "/foo.jpg", "/bar.jpg")
      assert {:error, %Error{tag: :invalid_signature}} = Signing.verify(tampered, @keys)
    end

    test "errors :invalid_signature when no key matches" do
      signed = Signing.sign("/foo.jpg", ["other-key"])
      assert {:error, %Error{tag: :invalid_signature}} = Signing.verify(signed, @keys)
    end
  end

  describe "verify/3 — expiry" do
    test "passes when :exp is in the future" do
      future = System.system_time(:second) + 3600
      signed = Signing.sign("/foo.jpg", @keys, expires_at: future)
      assert :ok = Signing.verify(signed, @keys)
    end

    test "errors :signature_expired when :exp has passed" do
      past = System.system_time(:second) - 60
      signed = Signing.sign("/foo.jpg", @keys, expires_at: past)
      assert {:error, %Error{tag: :signature_expired}} = Signing.verify(signed, @keys)
    end

    test "expiry boundary uses :now option for deterministic comparison" do
      expiry = 2_000_000_000
      signed = Signing.sign("/foo.jpg", @keys, expires_at: expiry)

      assert :ok = Signing.verify(signed, @keys, now: expiry - 1)
      assert :ok = Signing.verify(signed, @keys, now: expiry)

      assert {:error, %Error{tag: :signature_expired}} =
               Signing.verify(signed, @keys, now: expiry + 1)
    end
  end

  describe "round-trip with realistic Cloudflare paths" do
    test "signs and verifies a /cdn-cgi/image URL" do
      path = "/cdn-cgi/image/width=200,format=webp/photos/sunset.jpg"
      signed = Signing.sign(path, @keys)
      assert :ok = Signing.verify(signed, @keys, required?: true)
    end

    test "signs and verifies a hosted URL with a variant tail" do
      path = "/acct123/img456/thumbnail"
      signed = Signing.sign(path, @keys)
      assert :ok = Signing.verify(signed, @keys, required?: true)
    end
  end
end
