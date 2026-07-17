defmodule Tour.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/notactuallytreyanastasio/party_line"

  def project do
    [
      app: :tour,
      version: @version,
      elixir: "~> 1.15",
      # Tour ships its hook colocated with the component. The extraction is a
      # compile-time macro, but the index.js manifest that makes
      # `phoenix-colocated/tour` resolvable is written by this compiler — a
      # library carrying colocated hooks has to run it, or consumers get an
      # unresolved import instead of a tour.
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Guided product tours for Phoenix LiveView: a spotlight that rides on top of your real UI.",
      package: package(),
      docs: docs(),
      name: "Tour",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_live_view, "~> 1.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
  end
end
