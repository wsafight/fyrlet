import Config

if interval = System.get_env("FYRLET_OBSERVER_HIBERNATE_AFTER_MS") do
  config :fyrlet,
         :observer_hibernate_after,
         if(interval == "infinity", do: :infinity, else: String.to_integer(interval))
end

if delay = System.get_env("FYRLET_INVALIDATION_FALLBACK_DELAY_S") do
  config :fyrlet, :invalidation_fallback_delay, String.to_integer(delay)
end

if ttl = System.get_env("FYRLET_IDEMPOTENCY_TTL_SECONDS") do
  config :fyrlet, :idempotency_ttl, String.to_integer(ttl)
end

if pool_size = System.get_env("POOL_SIZE") do
  config :fyrlet, Fyrlet.Repo, pool_size: String.to_integer(pool_size)
end

if database_url = System.get_env("DATABASE_URL") do
  config :fyrlet, Fyrlet.Repo, url: database_url
end

if config_env() != :test do
  config :fyrlet, FyrletWeb.Endpoint,
    http: [
      ip: if(config_env() == :prod, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}),
      port: String.to_integer(System.get_env("PORT", "4000"))
    ]

  if System.get_env("PHX_SERVER") in ["true", "1"] do
    config :fyrlet, FyrletWeb.Endpoint, server: true
  end
end

config :fyrlet,
       :cors_origins,
       System.get_env("CORS_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173")
       |> String.split(",", trim: true)

if config_env() == :prod do
  System.fetch_env!("DATABASE_URL")

  config :fyrlet, FyrletWeb.Endpoint,
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    check_origin: System.fetch_env!("ALLOWED_ORIGINS") |> String.split(",", trim: true)
end
