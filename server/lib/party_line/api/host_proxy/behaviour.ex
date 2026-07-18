defmodule PartyLine.API.HostProxy.Behaviour do
  @moduledoc "The seam the controller calls, so tests can stub the host hop."
  @callback chat(host :: map(), body :: map()) ::
              {:ok, map()} | {:error, term()}
end
