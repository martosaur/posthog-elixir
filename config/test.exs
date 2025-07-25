import Config

config :posthog, enable: false, test_mode: true

if File.exists?("config/integration.exs"), do: import_config("integration.exs")
