defmodule Synopticon.ContentStore do
  @moduledoc """
  Tiny in-memory content store with PubSub broadcasts.
  """

  use GenServer

  @topic "content"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, "", name: __MODULE__)
  end

  def topic, do: @topic

  def get do
    GenServer.call(__MODULE__, :get)
  end

  def set(content) when is_binary(content) do
    GenServer.call(__MODULE__, {:set, content})
  end

  @impl true
  def init(content), do: {:ok, content}

  @impl true
  def handle_call(:get, _from, content), do: {:reply, content, content}

  @impl true
  def handle_call({:set, content}, _from, _old_content) do
    Phoenix.PubSub.broadcast(Synopticon.PubSub, @topic, {:content_updated, content})
    {:reply, :ok, content}
  end
end
