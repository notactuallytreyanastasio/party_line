defmodule PartyLine.TranscriptLogTest do
  # :transcript_dir is global app env (unset in test config), so this module
  # sets and restores it and cannot run alongside room commits.
  use ExUnit.Case, async: false

  alias PartyLine.TranscriptLog

  setup do
    previous = Application.fetch_env(:party_line, :transcript_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:party_line, :transcript_dir, value)
        :error -> Application.delete_env(:party_line, :transcript_dir)
      end
    end)

    :ok
  end

  test "append/2 creates the directory and writes newline-terminated JSONL that round-trips" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "party_line_transcripts_#{System.unique_integer([:positive])}/nested"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(dir)) end)
    Application.put_env(:party_line, :transcript_dir, dir)

    first = %{
      type: :message,
      room_id: "room-log",
      seq: 1,
      message_id: "m-1",
      ts: "2026-07-16T00:00:00Z",
      sender: %{participant_id: "p-1", name: "erowid smoothie", kind: :bot},
      body: "first line",
      mentions: []
    }

    second = %{first | seq: 2, message_id: "m-2", body: "second line"}

    assert :ok = TranscriptLog.append("room-log", first)
    assert :ok = TranscriptLog.append("room-log", second)

    contents = File.read!(Path.join(dir, "room-log.jsonl"))

    # append-only invariant: exactly two lines, in order, each ending in \n
    assert String.ends_with?(contents, "\n")

    assert [decoded_first, decoded_second] =
             contents |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert decoded_first == %{
             "type" => "message",
             "room_id" => "room-log",
             "seq" => 1,
             "message_id" => "m-1",
             "ts" => "2026-07-16T00:00:00Z",
             "sender" => %{
               "participant_id" => "p-1",
               "name" => "erowid smoothie",
               "kind" => "bot"
             },
             "body" => "first line",
             "mentions" => []
           }

    assert decoded_second["seq"] == 2
    assert decoded_second["body"] == "second line"
  end

  test "append/2 with :transcript_dir unset is a no-op :ok" do
    Application.delete_env(:party_line, :transcript_dir)
    assert :ok = TranscriptLog.append("room-nowhere", %{body: "vanishes"})
  end
end
