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

  # Loopback used 2s with no retries. Prod dials a shared deciduous over the
  # public internet (https://deciduous.bobbby.online), so timeouts widen and
  # transient failures retry with backoff. These are defaults; a caller or test
  # can override any by putting the same key in the config map, which already
  # flows through every function here.
  @receive_timeout 15_000
  @connect_timeout 10_000
  @max_retries 2

  # Retry only genuinely transient statuses. 404 is DELIBERATELY excluded:
  # PartyLine.Memory.Ingest reads a 404 as "the graph vanished" and re-creates
  # it, so a 404 must surface on the first try, never be retried away.
  @retry_statuses [408, 429, 500, 502, 503, 504]

  @type config :: %{api_url: String.t(), token: String.t(), graph: String.t()}

  @doc "Create (or confirm) the graph. Idempotent server-side."
  @spec ensure_graph(config()) :: :ok | {:error, term()}
  def ensure_graph(%{api_url: api_url, graph: graph} = config) do
    case request(:put, "#{api_url}/api/v1/graphs/#{graph}", config, nil) do
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

  @doc """
  Call any graph tool by name and hand back its raw result.

  `add_node/2` and `link_nodes/2` are the shapes the ingest needs; this is for
  callers who are relaying a tool the *bot* chose — see
  `PartyLine.Memory.Broker`, which decides which of them are allowed.
  """
  @spec tool(config(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def tool(%{graph: graph} = config, tool_name, args), do: tool(config, graph, tool_name, args)

  # ── internals ────────────────────────────────────────────────────────────

  defp tool(%{api_url: api_url} = config, graph, tool, args) do
    url = "#{api_url}/api/v1/graphs/#{graph}/tools/#{tool}"

    case request(:post, url, config, args) do
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

  defp request(method, url, config, body) do
    opts =
      [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer #{config.token}"}],
        receive_timeout: Map.get(config, :receive_timeout, @receive_timeout),
        connect_options: [timeout: Map.get(config, :connect_timeout, @connect_timeout)],
        retry: &retry?/2,
        retry_delay: Map.get(config, :retry_delay, &backoff/1),
        max_retries: Map.get(config, :max_retries, @max_retries),
        retry_log_level: false
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

  # Req calls this per attempt. Only IDEMPOTENT requests retry: PUT (ensure_graph)
  # and reads. A tool call is a POST that appends a node, and a retry after an
  # ambiguous failure — a receive timeout where the server may already have
  # committed, or a gateway 5xx — would append the SAME node twice, with no way
  # to tell. A dropped write is recoverable (the JSONL transcript is the flight
  # recorder, and Ingest re-ensures on the next event), a duplicate node isn't.
  # So a POST never retries; a transient blip drops it and we move on.
  #
  # A 404 is excluded from retry regardless, so Ingest's "graph vanished,
  # re-create it" self-heal still fires on the first try.
  defp retry?(%{method: method}, _) when method not in [:get, :head, :put], do: false
  defp retry?(_request, %Req.Response{status: status}), do: status in @retry_statuses
  defp retry?(_request, exception) when is_exception(exception), do: true
  defp retry?(_request, _other), do: false

  # Exponential backoff with jitter, n 0-based: ~0.3s, ~0.6s. Kept short —
  # Ingest processes events serially, so a retry stalls that room's queue.
  defp backoff(n), do: trunc(:math.pow(2, n) * 300) + :rand.uniform(150)

  defp maybe_json(opts, nil), do: opts
  defp maybe_json(opts, body), do: Keyword.put(opts, :json, body)
end
