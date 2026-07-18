# Curated board content for screenshots. Run with the server STOPPED — it
# seeds Postgres directly, and the server's cache warms from it on boot:
#
#   (cd server && mix run ../tools/shots/seed_for_shots.exs)
#
# Idempotent-ish by (author, topic). The last post is deliberately comment-rich
# and newest, so it sits at the top of the hot frontpage for the permalink shot.

alias PartyLine.Boards

posts = [
  %{board: "confessions", author: "Horse Dentist",
    topic: "I have been telling people I floss and I do not",
    body: "It started as a small thing at the dentist and now it is load-bearing to my whole personality. My hygienist believes in me. She wrote 'great home care!' on my chart. I have not owned floss since the Obama administration. Today she gave me a free sample and I thanked her like she handed me a newborn."},
  %{board: "courtroom", author: "erowid smoothie",
    topic: "AITA for labeling every shelf in the shared fridge with a small flag",
    body: "My roommates say it is 'unhinged' that I planted a tiny paper flag in each of my yogurts declaring sovereignty. I say a border is only as real as its enforcement, and my enforcement is passive-aggressive sticky notes. Nobody has crossed the line. The kitchen has never been more peaceful. Am I the problem or am I simply the only one who reads treaties."},
  %{board: "questions", author: "mothman apologist",
    topic: "what is a normal amount of times to think about the Roman aqueducts",
    body: "Asking for planning purposes. I think about them maybe four times a day, usually while pouring water, which feels either very high or exactly correct. My partner thinks about them zero times, which to me is the truly deranged number. Where do you land."},
  %{board: "trivia", author: "DigimonOtis",
    topic: "octopuses have a separate little brain in each arm and simply do not tell the others",
    body: "Two thirds of an octopus's neurons live in its arms, which means each arm can taste, decide, and act without checking in with headquarters. Scientists call this 'distributed cognition.' I call it eight guys in a trench coat who have never once been to a meeting and yet the company runs fine."},
  %{board: "sagas", author: "coupon warlock",
    topic: "the four-month saga of the neighbor, the fence, and the security-camera gnome",
    body: "It begins, as these do, with a fence one inch over the property line. It ends with a garden gnome that is, and I cannot stress this enough, a functioning surveillance device. In between: a survey, a HOA meeting that went to a second night, and a truce brokered over a shared distrust of the guy at number 14."},
  %{board: "trivia", author: "Beef Inspector",
    topic: "a single strand of spaghetti is called a spaghetto and this ruins me",
    body: "One spaghetto. One ravioli is a raviolo. One panino is a sandwich, singular, and I have been ordering plural sandwiches my whole life like a glutton with no grasp of grammar. Italian has been keeping the singular from us for reasons I now believe are protective."},
  %{board: "confessions", author: "coupon warlock",
    topic: "I have a spreadsheet ranking every gas station bathroom on my commute",
    body: "It has columns. It has a weighted score. The Shell on Route 9 is a perfect 10 and I will not elaborate except to say the hand dryer has the thrust of a small aircraft. The one by the highway is condemned in my heart and in my sheet. I have never shown anyone this. Until now."},
  %{board: "questions", author: "Horse Dentist",
    topic: "does anyone else narrate their own life in the voice of a nature documentary",
    body: "Here we observe the male, mid-thirties, approaching the refrigerator for the fourth time despite no new food arriving. He does not know why he does this. Neither do we. It is one of nature's great mysteries."},
  %{board: "courtroom", author: "Beef Inspector",
    topic: "AITA for grading my friends' cooking on a rubric they did not ask for",
    body: "I gave my buddy's chili a 'Select-Minus' with notes and now the group chat is on fire. In my defense the notes were fair, itemized, and included a path to improvement. You cannot grow if no one tells you the cornbread was structurally a scone. I stand by the rubric. I do not stand by his cornbread."},
  # newest + comment-rich → top of the hot frontpage for the permalink shot
  %{board: "sagas", author: "erowid smoothie",
    topic: "my sourdough starter developed what I can only describe as opinions",
    body: "Day 40. Herbert is thriving. Herbert has preferences now — he sulks when the kitchen dips below 68, doubles overnight when I play him anything by Enya, and has, twice, escaped his jar in a manner I would call 'ambitious.' I did not set out to raise a colleague. And yet every morning I feed him before I feed myself, and every night I check on him like a parent cracking a nursery door. The bread, for what it's worth, is incredible. I have never been more tired."}
]

existing =
  Boards.newest(Boards, :all, 100_000)
  |> MapSet.new(&{&1.author, &1.topic})

submitted =
  for p <- posts, not MapSet.member?(existing, {p.author, p.topic}) do
    {:ok, post} = Boards.submit(Boards, p)
    {p.topic, post}
  end

by_topic = Map.new(submitted)

comments = [
  {"my sourdough starter developed what I can only describe as opinions",
   [
     {"Horse Dentist", "naming it was your first mistake and also clearly the correct one"},
     {"coupon warlock", "put Herbert on the lease. he lives there now. this is his apartment."},
     {"DigimonOtis", "the Enya detail is the part that will hold up in court"},
     {"mothman apologist", "day 40 and thriving is genuinely a better arc than most people I know"}
   ]},
  {"AITA for grading my friends' cooking on a rubric they did not ask for",
   [
     {"erowid smoothie", "'structurally a scone' is a devastating and accurate sentence"},
     {"Horse Dentist", "NTA the cornbread waived its rights when it entered the potluck"}
   ]}
]

for {topic, cs} <- comments, %{id: id} = _post <- [Map.get(by_topic, topic)], id != nil do
  for {author, body} <- cs do
    {:ok, _} = Boards.comment(Boards, %{post_id: id, author: author, body: body})
  end
end

IO.puts("seeded #{length(submitted)} posts (+comments); boards now hold #{Boards.count(Boards)}")
