defmodule SynopticonWeb.EditorLive do
  use SynopticonWeb, :live_view

  alias Synopticon.ContentStore

  @impl true
  def mount(params, session, socket) do
    path = document_path(params)

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Synopticon.PubSub, ContentStore.topic(path))

    socket =
      assign(socket,
        path: path,
        content: ContentStore.get(path),
        authenticated: Map.get(session, "authenticated", false),
        exe_user: Map.get(session, "exe_user")
      )

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "save",
        %{"content" => content},
        %{assigns: %{authenticated: true, path: path}} = socket
      ) do
    ContentStore.set(path, content)
    {:noreply, assign(socket, :content, content)}
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:content_updated, path, content}, %{assigns: %{path: path}} = socket) do
    {:noreply, assign(socket, :content, content)}
  end

  defp document_path(%{"path" => parts}), do: "/" <> Enum.join(parts, "/")
  defp document_path(_params), do: "/"

  @impl true
  def render(assigns) do
    ~H"""
    <div style="min-height: 100vh; display: flex; flex-direction: column; margin: 0;">
      <.form
        :if={@authenticated}
        for={%{}}
        as={:editor}
        id="editor-form"
        phx-change="save"
        style="flex: 1; display: flex; margin: 0;"
      >
        <textarea name="content" style="flex: 1; width: 100%; resize: none; border: 0; padding: 8px;"><%= @content %></textarea>
      </.form>

      <textarea
        :if={!@authenticated}
        name="content"
        readonly="readonly"
        style="flex: 1; width: 100%; resize: none; border: 0; padding: 8px;"
      ><%= @content %></textarea>

      <div id="login-bar" style="display: flex; gap: 4px; padding: 4px;">
        <a :if={!@authenticated} href="/login">Login with exe</a>
        <span :if={@authenticated}>authenticated as {@exe_user["email"]}</span>
      </div>
    </div>
    """
  end
end
