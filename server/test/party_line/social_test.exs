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

      # await the death ourselves: by the time our own :DOWN lands, the
      # registry's :DOWN is already queued ahead of the call below
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Buddies.online(buddies) == ["coupon warlock fan"]
    end

    test "two sessions of one name stay online until both close" do
      {:ok, buddies} = Buddies.start_link(name: nil)
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Buddies.register(buddies, "bobdawg", pid)
      :ok = Buddies.register(buddies, "bobdawg", self())

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Buddies.online(buddies) == ["bobdawg"]
    end

    test "count reports distinct names, not sessions" do
      {:ok, buddies} = Buddies.start_link(name: nil)
      pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Buddies.register(buddies, "bobdawg", pid)
      :ok = Buddies.register(buddies, "bobdawg", self())
      assert Buddies.count(buddies) == 1

      other = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Buddies.register(buddies, "coupon warlock fan", other)
      assert Buddies.count(buddies) == 2

      Process.exit(pid, :kill)
      Process.exit(other, :kill)
    end

    test "online sorts case-insensitively" do
      {:ok, buddies} = Buddies.start_link(name: nil)
      pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Buddies.register(buddies, "Zed rules", pid)
      :ok = Buddies.register(buddies, "ada", self())

      # raw byte order would put "Zed rules" first; downcased sort must not
      assert Buddies.online(buddies) == ["ada", "Zed rules"]

      Process.exit(pid, :kill)
    end
  end

  describe "dms" do
    test "delivers over both users' topics and keeps history" do
      {:ok, dms} = DMs.start_link(name: nil)
      Phoenix.PubSub.subscribe(PartyLine.PubSub, DMs.topic("ada"))

      {:ok, _} = DMs.send_dm(dms, "bo", "ada", "psst", [])
      assert_receive {:dm, "bo", %{body: "psst", from: "bo", to: "ada", kind: :text}}

      {:ok, _} = DMs.send_dm(dms, "ada", "bo", "what", [])
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

    test "history is capped at the newest 200 messages, oldest first" do
      {:ok, dms} = DMs.start_link(name: nil)

      for n <- 1..205 do
        {:ok, _} = DMs.send_dm(dms, "erowid smoothie", "horse dentist", "m-#{n}", [])
      end

      history = DMs.history(dms, "erowid smoothie", "horse dentist")
      assert length(history) == 200
      # the oldest five fell off; what remains is chronological
      assert hd(history).body == "m-6"
      assert List.last(history).body == "m-205"
    end

    test "a self-DM delivers exactly one copy" do
      {:ok, dms} = DMs.start_link(name: nil)
      Phoenix.PubSub.subscribe(PartyLine.PubSub, DMs.topic("coupon warlock fan"))

      {:ok, _} = DMs.send_dm(dms, "coupon warlock fan", "coupon warlock fan", "note to self", [])

      assert_receive {:dm, "coupon warlock fan", %{body: "note to self"}}
      refute_receive {:dm, _, _}
    end

    test "history for a pair that never messaged is empty" do
      {:ok, dms} = DMs.start_link(name: nil)
      assert DMs.history(dms, "erowid smoothie", "beef inspector") == []
    end

    test "multi-word lowercase names work as PubSub topics end-to-end" do
      {:ok, dms} = DMs.start_link(name: nil)
      Phoenix.PubSub.subscribe(PartyLine.PubSub, DMs.topic("erowid smoothie"))

      {:ok, _} = DMs.send_dm(dms, "horse dentist", "erowid smoothie", "u up", [])
      assert_receive {:dm, "horse dentist", %{body: "u up", to: "erowid smoothie"}}
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

    test "get returns the stored clip by id and nil for unknown ids", %{clips: clips} do
      messages = [
        %{sender_name: "erowid smoothie", kind: :bot, body: "trust the blender", ts: "t"}
      ]

      {:ok, clip} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "bobdawg"})

      assert Clips.get(clips, clip.id) == clip
      assert Clips.get(clips, "not-a-real-id") == nil
    end

    test "wall respects the limit argument", %{clips: clips} do
      messages = [%{sender_name: "coupon warlock", kind: :bot, body: "DEALS", ts: "t"}]

      {:ok, first} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "a"})
      {:ok, second} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "b"})
      {:ok, _third} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "c"})

      {:ok, _} = Clips.laugh(clips, first.id)
      {:ok, _} = Clips.laugh(clips, first.id)
      {:ok, _} = Clips.laugh(clips, second.id)

      assert [%{id: top}, %{id: runner_up}] = Clips.wall(clips, 2)
      assert {top, runner_up} == {first.id, second.id}
    end

    test "equal laughs tie-break newest-first", %{clips: clips} do
      messages = [%{sender_name: "Beef Inspector", kind: :bot, body: "graded: Prime", ts: "t"}]

      {:ok, older} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "a"})
      # separate the ISO8601 timestamps so the tie-break is deterministic
      Process.sleep(2)
      {:ok, newer} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "b"})

      assert [%{id: top}, %{id: bottom}] = Clips.wall(clips)
      assert {top, bottom} == {newer.id, older.id}
    end

    test "topic and note are optional and stored as nil", %{clips: clips} do
      messages = [%{sender_name: "erowid smoothie", kind: :bot, body: "hmm", ts: "t"}]
      {:ok, clip} = Clips.clip(clips, messages, %{room_id: "room-x", clipped_by: "bobdawg"})

      assert clip.topic == nil
      assert clip.note == nil
    end
  end
end
