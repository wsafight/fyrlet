import Config

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
