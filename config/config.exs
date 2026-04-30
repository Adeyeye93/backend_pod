# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pod,
  ecto_repos: [Pod.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :pod, PodWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PodWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pod.PubSub,
  live_view: [signing_salt: "z76P6eE8"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.

config :pod, Pod.Accounts.Guardian,
  issuer: "pod",
  ttl: {24, :hours},
  allow_refresh: true

config :ex_aws,
  # change to your actual AWS region when you create the bucket
  region: "us-east-1"

config :pod, :storage,
  adapter: (if System.get_env("USE_S3") == "true", do: :s3, else: :local),
  bucket: "podb",
  local_path: "priv/segments",
  base_url: (if System.get_env("USE_S3") == "true",
    do: "https://podb.s3.us-east-1.amazonaws.com",
    else: "http://localhost:4000/segments")

config :pod, Pod.Mailer, adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :pod, Oban,
  repo: Pod.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ],
  queues: [
    streams: 20,
    default: 10
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :pod, Pod.Repo, migration_primary_key: [name: :id, type: :binary_id]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
