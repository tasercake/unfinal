import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :unfinal, UnfinalWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ioJ0EM4JELcyyESvv5UF21NqmRBoZ7youXZONSmB1fS8q8gyIzrffPb5emr2IOVJ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# FakeObjectStore kept for legacy R2 archive tests only; normal test path uses SQLite.
config :unfinal, :object_store_adapter, Unfinal.FakeObjectStore

# SQLite is the default test storage mode. R2 mode is dead code (deleted).
config :unfinal, :storage_mode, :sqlite

config :unfinal, Unfinal.Repo, database: Path.expand("../tmp/unfinal-test.sqlite3", __DIR__)
