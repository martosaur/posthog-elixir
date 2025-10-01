import Config

config :posthog, enable: false

if File.exists?("config/dev.override.exs"), do: import_config("dev.override.exs")
