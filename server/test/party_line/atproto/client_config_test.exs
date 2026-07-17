defmodule PartyLine.ATProto.ClientConfigTest do
  # async: false — these tests mutate the :party_line, :atproto application
  # env that Client.config/0 reads, and the async atproto tests (plus any
  # future OAuthController tests) read Client.config() themselves. ExUnit runs
  # sync modules serially after the async ones, so there is no overlap.
  use ExUnit.Case, async: false

  alias PartyLine.ATProto.Client

  setup do
    original = Application.get_env(:party_line, :atproto)

    on_exit(fn ->
      # no config/*.exs sets this key today — restore the Endpoint fallback
      case original do
        nil -> Application.delete_env(:party_line, :atproto)
        value -> Application.put_env(:party_line, :atproto, value)
      end
    end)

    :ok
  end

  defp put_base(base), do: Application.put_env(:party_line, :atproto, base_url: base)

  describe "config/0 with a production base_url" do
    test "client_id is the metadata document URL and the redirect is the https callback" do
      put_base("https://party.example")
      cfg = Client.config()

      assert cfg.client_id == "https://party.example/oauth/client-metadata.json"
      assert cfg.redirect_uri == "https://party.example/oauth/callback"
      assert cfg.base_url == "https://party.example"
      # no loopback query params ride along in prod
      refute cfg.client_id =~ "?"
    end

    test "metadata/0 advertises the https callback under the document-URL client identity" do
      put_base("https://party.example")
      meta = Client.metadata()

      # atproto uses the metadata document URL AS the client identity —
      # a regression here breaks every real-world login
      assert meta["client_id"] == "https://party.example/oauth/client-metadata.json"
      assert meta["redirect_uris"] == ["https://party.example/oauth/callback"]
    end
  end

  describe "config/0 with a loopback base_url" do
    test "an explicit http://127.0.0.1 base still takes the loopback branch" do
      put_base("http://127.0.0.1:4002")
      cfg = Client.config()

      assert cfg.client_id =~ ~r{^http://localhost\?}
      # the redirect host stays the loopback IP, untouched by the
      # localhost → 127.0.0.1 rewrite
      assert cfg.redirect_uri == "http://127.0.0.1:4002/oauth/callback"
    end

    test "the loopback client_id query params round-trip exactly" do
      put_base("http://localhost:4002")
      cfg = Client.config()

      assert %URI{host: "localhost", query: query} = URI.parse(cfg.client_id)

      assert URI.decode_query(query) == %{
               "redirect_uri" => cfg.redirect_uri,
               "scope" => "atproto transition:generic"
             }

      assert cfg.redirect_uri == "http://127.0.0.1:4002/oauth/callback"
    end
  end
end
