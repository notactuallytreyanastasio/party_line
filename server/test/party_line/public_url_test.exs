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

  test "allow_private_urls (dev) admits loopback but still enforces the scheme" do
    Application.put_env(:party_line, :allow_private_urls, true)

    assert {:ok, _} = PublicUrl.validate("http://127.0.0.1:8377")
    assert {:ok, _} = PublicUrl.validate("http://localhost:8377")
    # the flag relaxes WHERE, never WHAT: http(s) only, and a host is required
    assert {:error, :invalid_url} = PublicUrl.validate("ftp://127.0.0.1")
    assert {:error, :invalid_url} = PublicUrl.validate("not a url")
  end
end
