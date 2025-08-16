defmodule PostHog.MixProject do
  use Mix.Project

  @version "2.0.0"
  @source_url "https://github.com/posthog/posthog-elixir"

  def project do
    [
      app: :posthog,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      mod: {PostHog.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: :posthog,
      maintainers: ["PostHog"],
      licenses: ["MIT"],
      description: "Official PostHog Elixir SDK",
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      favicon: "docs/favicon.svg",
      logo: "docs/favicon.svg",
      source_ref: "v#{@version}",
      source_url: @source_url,
      assets: %{
        "assets" => "assets"
      },
      extras: ["README.md", "CHANGELOG.md", "MIGRATION.md", "guides/advanced-configuration.md"],
      groups_for_modules: [
        Integrations: [PostHog.Integrations.Plug],
        Testing: [PostHog.Test]
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "MIGRATION.md"]
    ]
  end

  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5.10"},
      {:logger_json, "~> 7.0"},
      {:nimble_ownership, "~> 1.0"},
      # Development tools
      {:ex_doc, "~> 0.37", only: :dev, runtime: false},
      {:logger_handler_kit, "~> 0.4", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end
end
