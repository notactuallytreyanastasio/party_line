defmodule PartyLine.API.HostProxy do
  @moduledoc """
  Forwards a completion to a lent model, as the exchange.

  A neighbor who runs `serve-llm --funnel` exposes an OpenAI endpoint that
  accepts requests only from us — it trusts one secret, and the exchange is the
  only holder. So a public caller never reaches the host directly: they
  authenticate to the exchange (an atproto-bound key), and the exchange proxies
  here, presenting the host's secret. The host authenticates *us*, not the open
  internet.

  This is the sole path from the outside world to a lent model, and the sole
  place its private url + secret are used.
  """
  @behaviour PartyLine.API.HostProxy.Behaviour

  require Logger

  @receive_timeout 120_000

  @doc """
  POST an OpenAI chat-completion `body` to `host` (`%{url, secret, model, name}`).
  Returns `{:ok, completion_map}` or `{:error, :host_unreachable | {:host_status, n}}`.
  """
  @impl true
  def chat(%{url: url, secret: secret} = _host, body) do
    endpoint = String.trim_trailing(url, "/") <> "/v1/chat/completions"

    case Req.post(endpoint,
           json: body,
           auth: {:bearer, secret},
           receive_timeout: @receive_timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("host proxy: #{endpoint} returned #{status}")
        {:error, {:host_status, status}}

      {:error, reason} ->
        Logger.warning("host proxy: #{endpoint} unreachable: #{inspect(reason)}")
        {:error, :host_unreachable}
    end
  end
end
