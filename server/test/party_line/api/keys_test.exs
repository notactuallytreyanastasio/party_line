defmodule PartyLine.API.KeysTest do
  use PartyLine.DataCase, async: true

  alias PartyLine.API.Keys

  @did "did:plc:erowidsmoothie"

  test "mint returns a pl- token that authenticates back to its did" do
    assert {:ok, key, token} = Keys.mint(@did, "my laptop script")
    assert String.starts_with?(token, "pl-")
    assert key.did == @did
    assert key.label == "my laptop script"
    # the plaintext is never stored — only its hash and a display prefix
    assert key.token_hash != token
    assert String.starts_with?(key.token_prefix, "pl-")

    assert {:ok, @did} = Keys.authenticate(token)
  end

  test "a wrong or malformed token does not authenticate" do
    {:ok, _key, _token} = Keys.mint(@did)
    assert Keys.authenticate("pl-not-a-real-token") == :error
    assert Keys.authenticate("no-prefix") == :error
    assert Keys.authenticate("") == :error
  end

  test "a revoked key stops authenticating; a sibling key still works" do
    {:ok, revoked, revoked_token} = Keys.mint(@did)
    {:ok, _kept, kept_token} = Keys.mint(@did)

    :ok = Keys.revoke(revoked.id, @did)

    assert Keys.authenticate(revoked_token) == :error
    assert {:ok, @did} = Keys.authenticate(kept_token)
  end

  test "you can only revoke your own keys" do
    {:ok, key, token} = Keys.mint(@did)

    # someone else's did can't revoke it
    :ok = Keys.revoke(key.id, "did:plc:someoneelse")
    assert {:ok, @did} = Keys.authenticate(token)

    :ok = Keys.revoke(key.id, @did)
    assert Keys.authenticate(token) == :error
  end

  test "list returns a did's keys newest-first and touches last_used_at on use" do
    {:ok, _first, _t1} = Keys.mint(@did, "first")
    {:ok, _second, token2} = Keys.mint(@did, "second")

    assert [%{label: "second"}, %{label: "first"}] = Keys.list(@did)

    {:ok, @did} = Keys.authenticate(token2)
    used = Enum.find(Keys.list(@did), &(&1.label == "second"))
    assert used.last_used_at != nil
  end
end
