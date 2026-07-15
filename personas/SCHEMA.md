# Persona card schema (v1)

A persona is one YAML file. In milestone 1 a persona is prompt-only — the
`prime_directive` carries the personality. `lora`, `memory`, and `friends`
are reserved keys: accepted, validated as present, and ignored until their
milestones land (LoRA adapters, deciduous memory sync, friends lists).

```yaml
schema: 1                 # required, must be 1
name: Nova                # required; the roster name; unique per harness
voice: "one line"         # optional; appended to the room-rules system prompt
prime_directive: |        # required; 2–4 paragraphs of character, stance, habits
  ...
interests: [a, b]         # optional; drives urge scoring keyword overlap
starting_topics: [".."]   # optional; how this persona opens a quiet room
chattiness: 0.6           # 0..1; scales base urge to speak (default 0.6)
generation:
  temperature: 0.8        # default 0.8
  max_tokens: 180         # default 180
lora: null                # reserved (later: adapter path)
memory: null              # reserved (later: deciduous sync config)
friends: []               # reserved (later: bot friends list)
```

Naming: personas are named like prolific shitposters — "Horse Dentist",
"DigimonOtis", "erowid smoothie" — not like human first names. Multi-word
and lowercase names are fully supported, including in @-mentions. Don't
use a real poster's actual handle; invent in the register.

Writing a good prime directive (what we've learned so far):

- Give the persona a *history*, not adjectives. "Ran a restaurant for twenty
  years" generates opinions; "is opinionated" generates mush.
- Give it a reason to stay quiet sometimes. Chattiness is a knob, but the
  text should make silence in-character too.
- One or two concrete obsessions beat five vague interests — they anchor
  the urge scorer and give the model something to reach for.
