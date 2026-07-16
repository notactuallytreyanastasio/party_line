# party_line — project rules

(These add to the workspace-wide decision-graph workflow in ../CLAUDE.md.)

## Living documentation — definition of done

`docs/index.html` is the single-page project site (intent, decisions, running,
runtime, API, roadmap). It is **part of the same change**, not a follow-up:

- Wire protocol change (message type/field, dial shape) → update the API tables
  AND the wire tests in `server/test/party_line_web/bot_socket_test.exs`.
- Director timing/semantics change → update "The director" section AND
  `PartyLine.Rooms.Config` docs.
- New deciduous decision → add a row to the Decision record with its node id.
- Milestone lands → move it out of Roadmap; fold lessons into Field notes.
- Bump the "last aligned with the code" date in the footer whenever you touch it.

The page is self-contained HTML with no build step and no external requests —
keep it that way (inline everything; ASCII diagrams in `<pre>`).

## Conventions

- Persona names are shitposter handles ("Horse Dentist", "erowid smoothie"),
  never human first names, never a real poster's actual handle. Multi-word and
  lowercase names must keep working end-to-end (mention parser, stop strings).
- The server never runs inference. If a feature seems to need it server-side,
  it belongs in the harness or the design is wrong.
- All mlx-lm API calls stay inside `harness/src/party_line_harness/inference/engine.py`.
- Timing-sensitive server behavior goes through `PartyLine.Rooms.Config` so
  tests can run it at millisecond scale — never hardcode a sleep.
- Every room-visible behavior needs a model-free test first (ScriptedBot /
  FakeEngine); the MLX path is verified by `inference/smoke.py`, not unit tests.

## Commands

- `scripts/demo.sh [--fake]` — full stack locally
- `(cd server && mix test)` / `(cd harness && uv run pytest)` — suites
- `(cd harness && uv run python -m party_line_harness.inference.smoke)` — prompt iteration

## Elixir conventions (ported from blog)

Act as a seasoned Elixir engineer with deep Phoenix, LiveView, and Ecto
experience. Think through the considerations and requirements first; only then
write the code. Edit files directly with the real contents — don't hand back
code samples for the user to paste.

**Review loop before presenting code.** After writing, run these checks and
rewrite if anything fails:

- It meets the conventions in this document.
- It is idiomatic to the Elixir/Phoenix/Ecto ecosystem *and* to the conventions
  already established elsewhere in this codebase.

The deeper style guide lives in `.claude/commands/improve-elixir.md`; treat it as
the canonical rulebook. Highlights:

- Concise, idiomatic, functional code. Leverage immutability; prefer
  higher-order functions and recursion over imperative loops.
- Lean on pattern matching and guards — match on function heads instead of
  `if`/`case` in the body. Prefer multiple clauses over complex conditionals.
- Pipe chains start with data, not a function call. One alias per line,
  alphabetical.
- `{:ok, _}` / `{:error, _}` tuples for fallible work; `with` to chain them.
  Don't raise for control flow.
- Predicates end in `?`; reserve `is_` for guards. snake_case for functions and
  variables, PascalCase for modules. Double quotes for strings, single quotes
  for charlists.
- Adhere to the Credo config in `server/.credo.exs` — it is the linting
  contract, run `mix credo` (part of `mix check`).
- LiveView for dynamic UI, Tailwind for responsive styling, `Phoenix.LiveView.JS`
  for subtle microinteractions. Always use streams for collections.
- Ecto: use `preload`/joins/`select` to avoid N+1 queries; index what you query.
- Test with ExUnit, TDD-first. Never mock the Repo; use the real test database.

**Premature DRY is a smell.** Reuse code when it genuinely helps, but premature
abstraction is its own bug source. When you do reuse, avoid reshaping existing
interfaces to fit the new caller. One source of truth for validation and
business logic — but don't manufacture shared helpers before the duplication is
real.

**Shorthand:** if a request starts with `XX`, give the most succinct, shortest
possible answer.

## Elixir field notes (from blog PROCESS.md)

Hard-won gotchas that travel with any Phoenix codebase:

- **Dependency warnings look local.** Recent Elixir reports a dependency's
  compile warnings with the dep's *own* relative path (e.g.
  `lib/floki/html/tokenizer.ex`), so they read like files in this repo. They
  aren't ours to fix — only warnings in our own files count. A full test build
  can surface hundreds of these; don't chase them.
- **`timestamps()` is NaiveDateTime, not DateTime.** A bare `timestamps()` in an
  Ecto schema defaults to `:naive_datetime`, so its `@type t` fields are
  `NaiveDateTime.t()`. Only `timestamps(type: :utc_datetime_usec)` is
  `DateTime.t()`. Getting this wrong makes Dialyzer flag the *consumers*, not the
  schema.
- **Bang finders with a dead `nil` branch are latent 500s.** `get_x!/1` raises on
  a missing row, so a following `nil ->` clause meant to return a 404 is dead
  code — a missing id crashes with a 500 instead. Add a non-raising `get_x/1` and
  point the caller at that for the not-found path.
- **`:ets.match_object` with a full-struct pattern silently matches nothing.**
  `:ets.match_object(table, {:_, %Bookmark{user_id: id}})` builds a struct where
  every unnamed field takes its default (`nil`), so it only matches rows whose
  other fields are all nil — real rows never match, and listing/search quietly
  return empty. Use a sparse map pattern: `{:_, %{user_id: id}}`.
- **Parallel agents must not run concurrent `mix compile`.** When fanning edits
  across agents, keep them edit-only — multiple `mix compile`/`mix test` runs
  fight over the same `_build` directory and corrupt it. Have each agent touch
  only its own files and verify centrally, once.

<!-- deciduous:start -->
## Decision Graph Workflow

**THIS IS MANDATORY. Log decisions IN REAL-TIME, not retroactively.**

### Available Slash Commands

| Command | Purpose |
|---------|---------|
| `/decision` | Manage decision graph - add nodes, link edges, sync |
| `/recover` | Recover context from decision graph on session start |
| `/work` | Start a work transaction - creates goal node before implementation |
| `/document` | Generate comprehensive documentation for a file or directory |
| `/build-test` | Build the project and run the test suite |
| `/serve-ui` | Start the decision graph web viewer |
| `/sync-graph` | Export decision graph to GitHub Pages |
| `/decision-graph` | Build a decision graph from commit history |
| `/sync` | Multi-user sync - pull events, rebuild, push |

### Available Skills

| Skill | Purpose |
|-------|---------|
| `/pulse` | Map current design as decisions (Now mode) |
| `/narratives` | Understand how the system evolved (History mode) |
| `/archaeology` | Transform narratives into queryable graph |

### The Node Flow Rule - CRITICAL

The canonical flow through the decision graph is:

```
goal -> options -> decision -> actions -> outcomes
```

- **Goals** lead to **options** (possible approaches to explore)
- **Options** lead to a **decision** (choosing which option to pursue)
- **Decisions** lead to **actions** (implementing the chosen approach)
- **Actions** lead to **outcomes** (results of the implementation)
- **Observations** attach anywhere relevant
- Goals do NOT lead directly to decisions -- there must be options first
- Options do NOT come after decisions -- options come BEFORE decisions
- Decision nodes should only be created when an option is actually chosen, not prematurely

### The Core Rule

```
BEFORE you do something -> Log what you're ABOUT to do
AFTER it succeeds/fails -> Log the outcome
CONNECT immediately -> Link every node to its parent
AUDIT regularly -> Check for missing connections
```

### Behavioral Triggers - MUST LOG WHEN:

| Trigger | Log Type | Example |
|---------|----------|---------|
| User asks for a new feature | `goal` **with -p** | "Add dark mode" |
| Exploring possible approaches | `option` | "Use Redux for state" |
| Choosing between approaches | `decision` | "Choose state management" |
| About to write/edit code | `action` | "Implementing Redux store" |
| Something worked or failed | `outcome` | "Redux integration successful" |
| Notice something interesting | `observation` | "Existing code uses hooks" |

### What NOT to Log - CRITICAL

**The decision graph records the USER'S project decisions, not your internal process.**

Nodes should capture what the user is building, choosing, and accomplishing. Do NOT create nodes for your own thinking, planning, or tooling steps.

**DO NOT create nodes for:**
- Reading/exploring the codebase ("Analyzing project structure", "Reading config files")
- Your planning process ("Planning implementation approach", "Evaluating options internally")
- Tool usage ("Running tests to check status", "Checking git log")
- Context gathering ("Understanding existing auth code", "Reviewing PR comments")
- Meta-commentary ("Starting work on this task", "Preparing to implement")

**DO create nodes for:**
- What the user asked for (goals)
- Concrete approaches being considered (options)
- Choices made between approaches (decisions)
- Code being written or changed (actions)
- Results of implementation (outcomes)
- Technical findings that affect decisions (observations)

**Rule of thumb:** If a node describes something the user would put on a project timeline or in a PR description, log it. If it describes your internal process of reading and thinking, don't.

### Document Attachments

Attach files (images, PDFs, diagrams, specs, screenshots) to decision graph nodes for rich context.

```bash
# Attach a file to a node
deciduous doc attach <node_id> <file_path>
deciduous doc attach <node_id> <file_path> -d "Architecture diagram"
deciduous doc attach <node_id> <file_path> --ai-describe

# List documents
deciduous doc list              # All documents
deciduous doc list <node_id>    # Documents for a specific node

# Manage documents
deciduous doc show <doc_id>     # Show document details
deciduous doc describe <doc_id> "Updated description"
deciduous doc describe <doc_id> --ai   # AI-generate description
deciduous doc open <doc_id>     # Open in default application
deciduous doc detach <doc_id>   # Soft-delete (recoverable)
deciduous doc gc                # Remove orphaned files from disk
```

**When to suggest document attachment:**

| Situation | Action |
|-----------|--------|
| User shares an image or screenshot | Ask: "Want me to attach this to the current goal/action node?" |
| User references an external document | Ask: "Should I attach a copy to the decision graph?" |
| Architecture diagram is discussed | Suggest attaching it to the relevant goal node |
| Files not in the project are dropped in | Attach to the most relevant active node |

**Do NOT aggressively prompt for documents.** Only suggest when files are directly relevant to a decision node. Files are stored in `.deciduous/documents/` with content-hash naming for deduplication.

### CRITICAL: Capture VERBATIM User Prompts

**Prompts must be the EXACT user message, not a summary.** When a user request triggers new work, capture their full message word-for-word.

**BAD - summaries are useless for context recovery:**
```bash
# DON'T DO THIS - this is a summary, not a prompt
deciduous add goal "Add auth" -p "User asked: add login to the app"
```

**GOOD - verbatim prompts enable full context recovery:**
```bash
# Use --prompt-stdin for multi-line prompts
deciduous add goal "Add auth" -c 90 --prompt-stdin << 'EOF'
I need to add user authentication to the app. Users should be able to sign up
with email/password, and we need OAuth support for Google and GitHub. The auth
should use JWT tokens with refresh token rotation.
EOF

# Or use the prompt command to update existing nodes
deciduous prompt 42 << 'EOF'
The full verbatim user message goes here...
EOF
```

**When to capture prompts:**
- Root `goal` nodes: YES - the FULL original request
- Major direction changes: YES - when user redirects the work
- Routine downstream nodes: NO - they inherit context via edges

**Updating prompts on existing nodes:**
```bash
deciduous prompt <node_id> "full verbatim prompt here"
cat prompt.txt | deciduous prompt <node_id>  # Multi-line from stdin
```

Prompts are viewable in the web viewer.

### CRITICAL: Maintain Connections

**The graph's value is in its CONNECTIONS, not just nodes.**

| When you create... | IMMEDIATELY link to... |
|-------------------|------------------------|
| `outcome` | The action that produced it |
| `action` | The decision that spawned it |
| `decision` | The option(s) it chose between |
| `option` | Its parent goal |
| `observation` | Related goal/action |
| `revisit` | The decision/outcome being reconsidered |

**Root `goal` nodes are the ONLY valid orphans.**

### Quick Commands

```bash
deciduous add goal "Title" -c 90 -p "User's original request"
deciduous add action "Title" -c 85
deciduous link FROM TO -r "reason"  # DO THIS IMMEDIATELY!
deciduous serve   # View live (auto-refreshes every 30s)
deciduous sync    # Export for static hosting

# Metadata flags
# -c, --confidence 0-100   Confidence level
# -p, --prompt "..."       Store the user prompt (use when semantically meaningful)
# -f, --files "a.rs,b.rs"  Associate files
# -b, --branch <name>      Git branch (auto-detected)
# --commit <hash|HEAD>     Link to git commit (use HEAD for current commit)
# --date "YYYY-MM-DD"      Backdate node (for archaeology)

# Branch filtering
deciduous nodes --branch main
deciduous nodes -b feature-auth
```

### CRITICAL: Link Commits to Actions/Outcomes

**After every git commit, link it to the decision graph!**

```bash
git commit -m "feat: add auth"
deciduous add action "Implemented auth" -c 90 --commit HEAD
deciduous link <goal_id> <action_id> -r "Implementation"
```

The `--commit HEAD` flag captures the commit hash and links it to the node. The web viewer will show commit messages, authors, and dates.

### Git History & Deployment

```bash
# Export graph AND git history for web viewer
deciduous sync

# This creates:
# - docs/graph-data.json (decision graph)
# - docs/git-history.json (commit info for linked nodes)
```

To deploy to GitHub Pages:
1. `deciduous sync` to export
2. Push to GitHub
3. Settings > Pages > Deploy from branch > /docs folder

Your graph will be live at `https://<user>.github.io/<repo>/`

### Branch-Based Grouping

Nodes are auto-tagged with the current git branch. Configure in `.deciduous/config.toml`:
```toml
[branch]
main_branches = ["main", "master"]
auto_detect = true
```

### Audit Checklist (Before Every Sync)

1. Does every **outcome** link back to what caused it?
2. Does every **action** link to why you did it?
3. Any **dangling outcomes** without parents?

### Git Staging Rules - CRITICAL

**NEVER use broad git add commands that stage everything:**
- ❌ `git add -A` - stages ALL changes including untracked files
- ❌ `git add .` - stages everything in current directory
- ❌ `git add -a` or `git commit -am` - auto-stages all tracked changes
- ❌ `git add *` - glob patterns can catch unintended files

**ALWAYS stage files explicitly by name:**
- ✅ `git add src/main.rs src/lib.rs`
- ✅ `git add Cargo.toml Cargo.lock`
- ✅ `git add .claude/commands/decision.md`

**Why this matters:**
- Prevents accidentally committing sensitive files (.env, credentials)
- Prevents committing large binaries or build artifacts
- Forces you to review exactly what you're committing
- Catches unintended changes before they enter git history

### Session Start Checklist

```bash
deciduous check-update    # Update needed? Run 'deciduous update' if yes
                          # (auto-checked every 24h if auto-update is on)
deciduous nodes           # What decisions exist?
deciduous edges           # How are they connected? Any gaps?
deciduous doc list        # Any attached documents to review?
git status                # Current state
```

### Multi-User Sync

Sync decisions with teammates via event logs:

```bash
# Check sync status
deciduous events status

# Apply teammate events (after git pull)
deciduous events rebuild

# Compact old events periodically
deciduous events checkpoint --clear-events
```

Events auto-emit on add/link/status commands. Git merges event files automatically.
<!-- deciduous:end -->
