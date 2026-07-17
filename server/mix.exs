defmodule PartyLine.MixProject do
  use Mix.Project

  def project do
    [
      app: :party_line,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      compile_options: [:debug_info],
      # Assay (incremental Dialyzer) configuration. Analyze the project plus its
      # deps for accurate success typing, but only surface warnings for our code.
      assay: [
        dialyzer: [
          # :crypto and :mix aren't pulled in by :project_plus_deps but our code
          # (random ids, hashing) and mix tasks call them — include them so they
          # resolve instead of producing "unknown function" false positives.
          # :ex_unit is needed because `mix check` runs in the :test env, where
          # test/support (ConnCase) compiles into the app and calls ExUnit.
          apps: [:project_plus_deps, :crypto, :mix, :ex_unit],
          warning_apps: :project
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {PartyLine.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, check: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:mint_web_socket, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:assay, "~> 0.5", runtime: false, only: [:dev, :test]},
      # atproto primitives: DPoP proofs, PKCE, DID/handle resolution.
      # No library does the full OAuth orchestration (PAR/authorize/token) —
      # that lives in PartyLine.ATProto.OAuth — but this covers the crypto.
      {:aether_atproto, "~> 0.1.5"},
      {:jose, "~> 1.11"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind party_line", "esbuild party_line"],
      "assets.deploy": [
        "tailwind party_line --minify",
        "esbuild party_line --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      check: ["format --check-formatted", "credo", "test", "assay"]
    ]
  end
end
