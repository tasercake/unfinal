defmodule UnfinalWeb.Presence do
  use Phoenix.Presence,
    otp_app: :unfinal,
    pubsub_server: Unfinal.PubSub
end
