defmodule PartyLine.API.Keys do
  @moduledoc """
  Minting and checking API keys for the completion endpoint.

  Identity comes from atproto: `mint/2` is only ever called from a signed-in
  session and stamps the caller's `did` onto the key. The token itself is a
  high-entropy random string (`pl-…`) shown to the user exactly once; we keep
  only its sha256, so a database leak can't be replayed as a credential.

  `authenticate/1` is the hot path — every API request runs it — so it's a
  single indexed lookup on the hash, with a fire-and-forget `last_used_at`
  touch that never blocks the request.
  """
  import Ecto.Query, only: [from: 2]

  alias PartyLine.API.Key
  alias PartyLine.Repo

  @prefix "pl-"

  @doc """
  Mint a key for `did`. Returns `{:ok, key, token}` where `token` is the
  plaintext — surface it once and never store it. `key` is the durable record.
  """
  @spec mint(String.t(), String.t()) :: {:ok, Key.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def mint(did, label \\ "default") when is_binary(did) do
    token = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    attrs = %{
      id: gen_id(),
      did: did,
      label: label_or_default(label),
      token_prefix: String.slice(token, 0, 11) <> "…",
      token_hash: hash(token)
    }

    case %Key{} |> Key.changeset(attrs) |> Repo.insert() do
      {:ok, key} -> {:ok, key, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Resolve a bearer token to its owner's `did`, or `:error`. Revoked keys never
  authenticate. Touches `last_used_at` best-effort.
  """
  @spec authenticate(String.t()) :: {:ok, String.t()} | :error
  def authenticate(@prefix <> _ = token) do
    hash = hash(token)

    case Repo.one(from(k in Key, where: k.token_hash == ^hash and is_nil(k.revoked_at))) do
      %Key{did: did} = key ->
        touch(key)
        {:ok, did}

      nil ->
        :error
    end
  end

  def authenticate(_), do: :error

  @doc "All of a did's keys, newest first (revoked ones included, flagged)."
  @spec list(String.t()) :: [Key.t()]
  def list(did) do
    Repo.all(from(k in Key, where: k.did == ^did, order_by: [desc: k.created_at]))
  end

  @doc "Revoke a key the caller owns. A no-op for a key that isn't theirs."
  @spec revoke(String.t(), String.t()) :: :ok
  def revoke(id, did) do
    now = DateTime.utc_now()

    {_n, _} =
      Repo.update_all(
        from(k in Key, where: k.id == ^id and k.did == ^did and is_nil(k.revoked_at)),
        set: [revoked_at: now, updated_at: now]
      )

    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp touch(%Key{} = key) do
    now = DateTime.utc_now()
    Repo.update_all(from(k in Key, where: k.id == ^key.id), set: [last_used_at: now])
    key
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp label_or_default(label) when is_binary(label) do
    case String.trim(label) do
      "" -> "default"
      trimmed -> String.slice(trimmed, 0, 80)
    end
  end

  defp label_or_default(_), do: "default"

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
