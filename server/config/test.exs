import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :party_line, PartyLineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Lbtt8KtSMQ14uIgN+lf2gMltvRiSpsVEw3zadNljSx8tfOG+P0xlWs9+OFfUNj2Q",
  # the bot-socket integration tests drive a real WebSocket
  server: true

# fast director so socket integration tests run in real time
config :party_line, :room_config,
  cooldown_min: 10,
  cooldown_max: 20,
  reading_ms_per_char: 0,
  bid_window: 80,
  fast_bid_window: 60,
  grant_deadline: 300,
  preempt_cooldown: 10,
  silence_backoff: [30, 40, 50, 60]

# In test we don't send emails
config :party_line, PartyLine.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
