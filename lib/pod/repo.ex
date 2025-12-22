defmodule Pod.Repo do
  use Ecto.Repo,
    otp_app: :pod,
    adapter: Ecto.Adapters.Postgres
end
