defmodule PartyLineWeb.KeysLive do
  @moduledoc """
  `/keys` — mint and manage API keys for the completion endpoint.

  Identity is atproto: you have to be signed in with your handle to be here,
  and every key is stamped with your `did`. A freshly minted token is shown
  exactly once — there's no way to recover it, only to revoke it and mint
  another.
  """
  use PartyLineWeb, :live_view

  alias PartyLine.API.Keys

  @impl true
  def mount(_params, session, socket) do
    did = session["did"]

    {:ok,
     socket
     |> assign(
       page_title: "API keys",
       did: did,
       handle: session["handle"],
       fresh: nil,
       curl_example: curl_example(PartyLineWeb.Endpoint.url())
     )
     |> load_keys()}
  end

  # built in Elixir so the JSON braces aren't read as HEEx interpolation
  defp curl_example(base_url) do
    """
    curl #{base_url}/v1/chat/completions \\
      -H "Authorization: Bearer $PARTY_LINE_KEY" \\
      -H "Content-Type: application/json" \\
      -d '{"model":"party-line-auto","messages":[{"role":"user","content":"why do cats knead?"}]}'\
    """
  end

  @impl true
  def handle_event("mint", %{"label" => label}, %{assigns: %{did: did}} = socket)
      when is_binary(did) do
    case Keys.mint(did, label) do
      {:ok, _key, token} -> {:noreply, socket |> assign(fresh: token) |> load_keys()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "couldn't mint a key — try again")}
    end
  end

  def handle_event("revoke", %{"id" => id}, %{assigns: %{did: did}} = socket)
      when is_binary(did) do
    Keys.revoke(id, did)
    {:noreply, socket |> assign(fresh: nil) |> load_keys()}
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, fresh: nil)}

  defp load_keys(%{assigns: %{did: did}} = socket) when is_binary(did),
    do: assign(socket, keys: Keys.list(did))

  defp load_keys(socket), do: assign(socket, keys: [])

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(%{did: nil} = assigns) do
    ~H"""
    <div class="retro-desktop">
      <.skin_toggle />
      <div class="retro-window">
        <div class="retro-titlebar">
          <.link navigate={~p"/"} class="retro-close" aria-label="close"></.link>
          <span class="retro-titlebar-title">🔑 API keys</span>
        </div>
        <div class="retro-body">
          <p>Programmatic access to the exchange is keyed to your atproto identity.</p>
          <p>Sign in with your handle to mint a key.</p>
          <.form for={%{}} action={~p"/oauth/login"} method="post" class="retro-askform">
            <input
              type="text"
              name="handle"
              placeholder="you.bsky.social"
              class="retro-input"
              required
            />
            <button type="submit" class="retro-btn">sign in</button>
          </.form>
        </div>
        <div class="retro-statusbar"><span>signed out</span></div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="retro-desktop">
      <.skin_toggle />
      <div class="retro-window">
        <div class="retro-titlebar">
          <.link navigate={~p"/"} class="retro-close" aria-label="close"></.link>
          <span class="retro-titlebar-title">🔑 API keys · {@handle}</span>
        </div>

        <div class="retro-body">
          <div :if={@fresh} class="retro-asknote">
            <strong>Copy this now — it's shown once.</strong>
            <pre class="retro-keytoken">{@fresh}</pre>
            <button type="button" class="retro-btn" phx-click="dismiss">got it</button>
          </div>

          <form phx-submit="mint" class="retro-askform">
            <input
              type="text"
              name="label"
              placeholder="what's this key for? (e.g. my laptop script)"
              class="retro-input"
            />
            <button type="submit" class="retro-btn">mint a key</button>
          </form>

          <table class="retro-keytable">
            <thead>
              <tr>
                <th>label</th><th>key</th><th>created</th><th>last used</th><th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={k <- @keys} class={k.revoked_at && "is-revoked"}>
                <td>{k.label}</td>
                <td><code>{k.token_prefix}</code></td>
                <td>{Calendar.strftime(k.created_at, "%Y-%m-%d")}</td>
                <td>{k.last_used_at && Calendar.strftime(k.last_used_at, "%Y-%m-%d")}</td>
                <td>
                  <span :if={k.revoked_at} class="retro-keyrevoked">revoked</span>
                  <button
                    :if={is_nil(k.revoked_at)}
                    type="button"
                    class="retro-btn"
                    phx-click="revoke"
                    phx-value-id={k.id}
                    data-confirm="Revoke this key? Anything using it stops working."
                  >
                    revoke
                  </button>
                </td>
              </tr>
              <tr :if={@keys == []}>
                <td colspan="5">no keys yet — mint one above.</td>
              </tr>
            </tbody>
          </table>

          <div class="retro-keyusage">
            <p>Point any OpenAI or Anthropic client at the exchange:</p>
            <pre class="retro-keytoken">{@curl_example}</pre>
          </div>
        </div>
        <div class="retro-statusbar"><span>signed in as {@handle}</span></div>
      </div>
    </div>
    """
  end
end
