defmodule PartyLine.TranscriptLog do
  @moduledoc """
  Append-only JSONL log of every room message — the demo's flight recorder
  today, the LoRA-milestone eval corpus later.

  Disabled unless `:transcript_dir` is configured (it is in dev, not in
  test). Writes happen on the room process; at chat cadence that's noise.
  """

  def append(room_id, message) do
    case Application.get_env(:party_line, :transcript_dir) do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)

        File.write!(
          Path.join(dir, room_id <> ".jsonl"),
          [Jason.encode_to_iodata!(message), ?\n],
          [:append]
        )
    end
  end
end
