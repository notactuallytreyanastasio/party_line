defmodule PartyLine.PublicUrl do
  @moduledoc """
  Validate that a URL is a *public* `http`/`https` address the exchange may
  safely make an outbound request to.

  The exchange (and a pipeline driver it hands endpoints to) fetches these
  URLs, so a registrant must not be able to point one at our own network:
  loopback, link-local (incl. the cloud metadata endpoint at 169.254.169.254),
  and private ranges are rejected, as are obvious internal names. This blocks
  SSRF via IP literals; a public name that resolves to a private address is a
  residual mitigated with `redirect: false` at request time.

  One source of truth, shared by every catalog that stores a caller-supplied
  URL (`Hosts`, `Pipelines`).

  Dev only: `config :party_line, allow_private_urls: true` skips the private
  checks (the scheme is still enforced), so the whole federation — exchange,
  lent hosts, pipeline shards — can run on one laptop. Never set it where the
  exchange faces callers you don't trust.
  """

  import Bitwise

  @doc "Returns `{:ok, url}` for a public http(s) URL, else `{:error, reason}`."
  def validate("http://" <> rest = url) when rest != "", do: check(url)
  def validate("https://" <> rest = url) when rest != "", do: check(url)
  def validate(_), do: {:error, :invalid_url}

  defp check(url) do
    host = url |> URI.parse() |> Map.get(:host) |> to_string() |> String.downcase()

    cond do
      host == "" -> {:error, :invalid_url}
      allow_private?() -> {:ok, url}
      host in ~w(localhost metadata.google.internal metadata) -> {:error, :private_url}
      String.ends_with?(host, [".local", ".internal"]) -> {:error, :private_url}
      private_ip?(host) -> {:error, :private_url}
      true -> {:ok, url}
    end
  end

  defp allow_private?, do: Application.get_env(:party_line, :allow_private_urls, false)

  defp private_ip?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> blocked_ip?(addr)
      _ -> false
    end
  end

  # ── IPv4 ────────────────────────────────────────────────────────────────
  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b in 16..31, do: true
  defp blocked_ip?({0, 0, 0, 0}), do: true

  # ── IPv6 ──────────────────────────────────────────────────────────────────
  # loopback (::1) and unspecified (::)
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv4-mapped (::ffff:a.b.c.d) — the classic SSRF bypass: unwrap to the real
  # IPv4 and apply the IPv4 rules, so [::ffff:127.0.0.1] can't slip through.
  defp blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, x, y}), do: blocked_ip?(unmap(x, y))
  # deprecated IPv4-compatible (::a.b.c.d), likewise unwrapped (::1/:: handled above)
  defp blocked_ip?({0, 0, 0, 0, 0, 0, x, y}), do: blocked_ip?(unmap(x, y))
  # link-local (fe80::/10) and unique-local (fc00::/7)
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp blocked_ip?(_), do: false

  # the two low hextets of a v4-in-v6 address back into an {a,b,c,d} tuple
  defp unmap(x, y), do: {x >>> 8, x &&& 0xFF, y >>> 8, y &&& 0xFF}
end
