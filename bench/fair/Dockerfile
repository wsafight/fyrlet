# The working tree: Fyrlet as a dependency of the inbox example application, as a host app would use it.
FROM elixir:1.20.5 AS build
ENV MIX_ENV=prod FYRLET_CHANNEL_HIBERNATE_MS=15000
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
COPY lib lib
COPY priv priv
COPY examples/inbox examples/inbox
RUN mix deps.get --only prod
WORKDIR /app/examples/inbox
RUN mix release

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/examples/inbox/_build/prod/rel/inbox_example ./
ENV PHX_SERVER=true PORT=4200
CMD ["bin/inbox_example", "start"]
