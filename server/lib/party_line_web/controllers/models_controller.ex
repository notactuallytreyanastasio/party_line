defmodule PartyLineWeb.ModelsController do
  @moduledoc """
  `GET /v1/models` — what's answerable right now. Each online persona is a model
  id you can target in the `model` field; each **lent** model (a neighbor's
  `serve-llm`, reached through the exchange proxy) is another; and
  `party-line-auto` lets the router pick a persona. The list is live — it
  shrinks when laptops close.
  """
  use PartyLineWeb, :controller

  alias PartyLine.Agents.Card

  def index(conn, _params) do
    created = System.system_time(:second)

    personas =
      bots_server()
      |> PartyLine.Bots.cards()
      |> Enum.map(fn card ->
        %{
          id: card.persona,
          object: "model",
          created: created,
          owned_by: "party-line",
          party_line: %{kind: "persona", model: card.model, byline: Card.byline(card)}
        }
      end)

    lent =
      hosts_server()
      |> PartyLine.Hosts.list()
      |> Enum.filter(& &1.served)
      |> Enum.map(fn host ->
        %{
          id: host.model,
          object: "model",
          created: created,
          owned_by: "lent",
          party_line: %{kind: "lent", host: host.name}
        }
      end)

    auto = %{
      id: "party-line-auto",
      object: "model",
      created: created,
      owned_by: "party-line",
      party_line: %{kind: "router", byline: "the exchange, routed"}
    }

    json(conn, %{object: "list", data: [auto | personas] ++ lent})
  end

  defp bots_server, do: Application.get_env(:party_line, :api_bots, PartyLine.Bots)
  defp hosts_server, do: Application.get_env(:party_line, :api_hosts, PartyLine.Hosts)
end
