import Config

config :fyrlet, Fyrlet.RuntimeConfig.settings(config_env())

config :notify_example, sender: System.get_env("MAIL_FROM"), delivery_adapter: "email"
config :fyrlet, :effect_secrets, %{"mail_provider" => System.get_env("RESEND_API_KEY")}
config :fyrlet_effect_email, allowed_senders: List.wrap(System.get_env("MAIL_FROM"))
