defmodule PartyLineWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token auth for the completion API. Reads `Authorization: Bearer pl-…`,
  resolves it to the owning atproto `did`, and stamps it on the conn as
  `:did`. A missing or bad key is a 401 in the OpenAI error shape, so the same
  clients that talk to OpenAI understand the failure without special-casing us.
  """
  import Plug.Conn

  alias PartyLine.API.Keys

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, did} <- Keys.authenticate(String.trim(token)) do
      assign(conn, :did, did)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    body =
      Jason.encode!(%{
        error: %{
          message:
            "No valid API key provided. Pass `Authorization: Bearer pl-…`; " <>
              "mint one while signed in with your atproto handle at /keys.",
          type: "invalid_request_error",
          code: "invalid_api_key"
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
