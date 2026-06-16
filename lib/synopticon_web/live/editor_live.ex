defmodule SynopticonWeb.EditorLive do
  use SynopticonWeb, :live_view

  alias Synopticon.ContentStore

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Synopticon.PubSub, ContentStore.topic())

    socket =
      assign(socket,
        content: ContentStore.get(),
        authenticated: Map.get(session, "authenticated", false),
        password_error: Map.get(session, "password_error", false)
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("save", %{"content" => content}, %{assigns: %{authenticated: true}} = socket) do
    ContentStore.set(content)
    {:noreply, assign(socket, :content, content)}
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:content_updated, content}, socket) do
    {:noreply, assign(socket, :content, content)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="min-height: 100vh; display: flex; flex-direction: column; margin: 0;">
      <.form
        :if={@authenticated}
        for={%{}}
        as={:editor}
        phx-change="save"
        style="flex: 1; display: flex; margin: 0;"
      >
        <textarea name="content" style="flex: 1; width: 100%; resize: none; border: 0; padding: 8px;"><%= @content %></textarea>
      </.form>

      <textarea
        :if={!@authenticated}
        name="content"
        style="flex: 1; width: 100%; resize: none; border: 0; padding: 8px;"
      ><%= @content %></textarea>

      <form action="/login" method="post" style="display: flex; gap: 4px; padding: 4px;">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input type="password" name="password" placeholder="password" />
        <button type="submit">log in</button>
        <span :if={@authenticated}>authenticated</span>
        <span :if={@password_error}>wrong password</span>
      </form>
    </div>
    """
  end
end
