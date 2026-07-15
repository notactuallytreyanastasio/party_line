defmodule PartyLine.Memory.Client do
  @moduledoc """
  Thin HTTP wrapper around the deciduous API server (branch `feat/api-server`).

  Every function takes a config map `%{api_url, token, graph}` and returns a
  tagged tuple. **Nothing here ever raises** — connection failures, timeouts
  and non-2xx responses all collapse to `{:error, reason}` so the caller can
  degrade gracefully. Clients must never assume the daemon is up.

  API contract:

  - `Authorization: Bearer <token>` on every request, JSON bodies.
  - Envelope: `{"ok": true, "data": ...}` | `{"ok": false, "error": "..."}`.
  - `PUT  /api/v1/graphs/{id}` — create graph, idempotent (200/201).
  - `POST /api/v1/graphs/{id}/tools/{tool}` — body is the tool's args,
    data is `{"is_error": bool, "result": <tool payload>}`.
  """

  @timeout 2_000

  @type config :: %{api_url: String.t(), token: String.t(), graph: String.t()}

  @doc "Create (or confirm) the graph. Idempotent server-side."
  @spec ensure_graph(config()) :: :ok | {:error, term()}
  def ensure_graph(%{api_url: api_url, token: token, graph: graph}) do
    case request(:put, "#{api_url}/api/v1/graphs/#{graph}", token, nil) do
      {:ok, _status, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Add a node. `args` is the `add_node` tool payload, e.g.
  `%{node_type: "observation", title: ..., description: ..., branch: ...}`.
  Returns `{:ok, node_id}` on success.
  """
  @spec add_node(config(), map()) :: {:ok, integer()} | {:error, term()}
  def add_node(%{graph: graph} = config, args) do
    case tool(config, graph, "add_node", args) do
      {:ok, %{"node_id" => node_id}} -> {:ok, node_id}
      {:ok, other} -> {:error, {:missing_node_id, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Link two nodes. `args` is the `link_nodes` payload `%{from_id, to_id, rationale}`."
  @spec link_nodes(config(), map()) :: :ok | {:error, term()}
  def link_nodes(%{graph: graph} = config, args) do
    case tool(config, graph, "link_nodes", args) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp tool(%{api_url: api_url, token: token}, graph, tool, args) do
    url = "#{api_url}/api/v1/graphs/#{graph}/tools/#{tool}"

    case request(:post, url, token, args) do
      {:ok, _status, %{"ok" => true, "data" => %{"is_error" => false} = data}} ->
        {:ok, Map.get(data, "result")}

      {:ok, _status, %{"ok" => true, "data" => %{"is_error" => true} = data}} ->
        {:error, {:tool_error, Map.get(data, "result")}}

      {:ok, _status, %{"ok" => false, "error" => error}} ->
        {:error, {:api_error, error}}

      {:ok, status, body} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, url, token, body) do
    opts =
      [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer #{token}"}],
        receive_timeout: @timeout,
        connect_options: [timeout: @timeout],
        retry: false
      ]
      |> maybe_json(body)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, status, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:http_status, status, resp_body}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp maybe_json(opts, nil), do: opts
  defp maybe_json(opts, body), do: Keyword.put(opts, :json, body)
end
