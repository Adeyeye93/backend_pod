FROM elixir:1.18.4

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y build-essential

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy mix files and install dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get

# Copy the rest of the app
COPY . .

# Compile the app
RUN mix compile

EXPOSE 4000

CMD ["mix", "phx.server"]