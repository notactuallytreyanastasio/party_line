defmodule PartyLine.SocialTest do
  use ExUnit.Case, async: false

  alias PartyLine.{Buddies, Clips, DMs}

  describe "buddies" do
    test "registered names are online until their process dies" do
      {:ok, buddies} = Buddies.start_link(name: nil)

      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Buddies.register(buddies, "bobdawg", pid)
      :ok = Buddies.register(buddies, "coupon warlock fan", self())
      assert Buddies.online(buddies) == ["bobdawg", "coupon warlock fan"]

      Process.exit(pid, :kill)
      # monitor delivery is async; sync via a second call
      Process.sleep(20)
      assert Buddies.online(buddies) == ["coupon warlock fan"]
    end

    test "two sessions of one name stay online until both close" do
      {:ok, buddies} = Buddies.start_link(name: nil)
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Buddies.register(buddies, "bobdawg", pid)
      :ok = Buddies.register(buddies, "bobdawg", self())

      Process.exit(pid, :kill)
      Process.sleep(20)
      assert Buddies.online(buddies) == ["bobdawg"]
    end
  end

  describe "dms" do
    test "delivers over both users' topics and keeps history" do
      {:ok, dms} = DMs.start_link(name: nil)
      Phoenix.PubSub.subscribe(PartyLine.PubSub, DMs.topic("ada"))

      {:ok, _} = DMs.send_dm(dms, "bo", "ada", "psst")
      assert_receive {:dm, "bo", %{body: "psst", from: "bo", to: "ada", kind: :text}}

      {:ok, _} = DMs.send_dm(dms, "ada", "bo", "what")
      assert [%{body: "psst"}, %{body: "what"}] = DMs.history(dms, "ada", "bo")
      # order of names doesn't matter
      assert length(DMs.history(dms, "bo", "ada")) == 2
    end

    test "clips travel as quoted DMs" do
      {:ok, dms} = DMs.start_link(name: nil)
      quoted = [%{sender_name: "Horse Dentist", kind: :bot, body: "the molars know", ts: "t"}]

      {:ok, message} = DMs.send_dm(dms, "bo", "ada", "look at this", kind: :clip, quoted: quoted)
      assert message.kind == :clip
      assert [%{body: "the molars know"}] = message.quoted
    end
  end

  describe "clips" do
    setup do
      path = Path.join(System.tmp_dir!(), "clips-test-#{System.unique_integer([:positive])}.dets")
      {:ok, clips} = Clips.start_link(name: nil, path: path)
      on_exit(fn -> File.rm(path) end)
      %{clips: clips, path: path}
    end

    test "clip, laugh, and rank the wall", %{clips: clips} do
      messages = [
        %{sender_name: "coupon warlock", kind: :bot, body: "the SAVING RITUAL", ts: "t"}
      ]

      {:ok, first} =
        Clips.clip(clips, messages, %{room_id: "room-x", topic: "deals", clipped_by: "bobdawg"})

      {:ok, second} =
        Clips.clip(clips, messages, %{
          room_id: "room-x",
          topic: "deals",
          clipped_by: "ada",
          note: "im crying"
        })

      {:ok, 1} = Clips.laugh(clips, second.id)
      assert {:error, :not_found} = Clips.laugh(clips, "nope")

      assert [top, runner_up] = Clips.wall(clips)
      assert top.id == second.id
      assert top.note == "im crying"
      assert top.laughs == 1
      assert runner_up.id == first.id
    end

    test "clips survive a restart", %{clips: clips, path: path} do
      messages = [%{sender_name: "Beef Inspector", kind: :bot, body: "graded: Prime", ts: "t"}]
      {:ok, _} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "bobdawg"})
      GenServer.stop(clips)

      {:ok, reopened} = Clips.start_link(name: nil, path: path)
      assert [%{messages: [%{body: "graded: Prime"}]}] = Clips.wall(reopened)
    end
  end
end
