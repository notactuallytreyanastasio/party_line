defmodule PartyLineWeb.ModelsController do
  @moduledoc """
  `GET /v1/models` — who's answerable right now. Each online persona is a
  model id you can target in the `model` field; `party-line-auto` lets the
  router pick. The list is live: it's whoever's leased a machine to the
  exchange this second, so it shrinks when laptops close.
  """
  use PartyLineWeb, :controller

  alias PartyLine.Agents.Card

  def index(conn, _params) do
    created = System.system_time(:second)

    online =
      bots_server()
      |> PartyLine.Bots.cards()
      |> Enum.map(fn card ->
        %{
          id: card.persona,
          object: "model",
          created: created,
          owned_by: "party-line",
          party_line: %{model: card.model, byline: Card.byline(card)}
        }
      end)

    auto = %{
      id: "party-line-auto",
      object: "model",
      created: created,
      owned_by: "party-line",
      party_line: %{
        model: "router picks by size and availability",
        byline: "the exchange, routed"
      }
    }

    json(conn, %{object: "list", data: [auto | online]})
  end

  defp bots_server, do: Application.get_env(:party_line, :api_bots, PartyLine.Bots)
end
