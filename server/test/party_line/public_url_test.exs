defmodule PartyLine.PublicUrlTest do
  # mutates the :allow_private_urls app env, so serialized
  use ExUnit.Case, async: false

  alias PartyLine.PublicUrl

  setup do
    on_exit(fn -> Application.delete_env(:party_line, :allow_private_urls) end)
  end

  test "by default, loopback/private/internal urls are rejected" do
    assert {:error, :private_url} = PublicUrl.validate("http://127.0.0.1:8377")
    assert {:error, :private_url} = PublicUrl.validate("http://localhost:8377")
    assert {:error, :private_url} = PublicUrl.validate("http://10.0.0.5")
    assert {:error, :private_url} = PublicUrl.validate("http://169.254.169.254/latest")
    assert {:ok, _} = PublicUrl.validate("https://host.tailnet.ts.net")
  end

  test "IPv6 literals can't smuggle a private address past the guard" do
    # loopback / unspecified / link-local / unique-local
    assert {:error, :private_url} = PublicUrl.validate("http://[::1]:8378")
    assert {:error, :private_url} = PublicUrl.validate("http://[::]:8378")
    assert {:error, :private_url} = PublicUrl.validate("http://[fe80::1]:8378")
    assert {:error, :private_url} = PublicUrl.validate("http://[fc00::1]:8378")

    # IPv4-mapped IPv6 — the classic SSRF bypass — must unwrap and be rejected
    assert {:error, :private_url} = PublicUrl.validate("http://[::ffff:127.0.0.1]:8378")
    assert {:error, :private_url} = PublicUrl.validate("http://[::ffff:169.254.169.254]/latest")
    assert {:error, :private_url} = PublicUrl.validate("http://[::ffff:10.0.0.1]")

    # a genuinely global IPv6 literal still passes
    assert {:ok, _} = PublicUrl.validate("http://[2606:4700:4700::1111]")
    # …and its mapped-public form unwraps to a public IPv4
    assert {:ok, _} = PublicUrl.validate("http://[::ffff:8.8.8.8]")
  end

  test "allow_private_urls (dev) admits loopback but still enforces the scheme" do
    Application.put_env(:party_line, :allow_private_urls, true)

    assert {:ok, _} = PublicUrl.validate("http://127.0.0.1:8377")
    assert {:ok, _} = PublicUrl.validate("http://localhost:8377")
    # the flag relaxes WHERE, never WHAT: http(s) only, and a host is required
    assert {:error, :invalid_url} = PublicUrl.validate("ftp://127.0.0.1")
    assert {:error, :invalid_url} = PublicUrl.validate("not a url")
  end
end
