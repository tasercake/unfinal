defmodule SynopticonWeb.EditorLive do
  use SynopticonWeb, :live_view

  alias Synopticon.ContentStore
  alias Synopticon.Writers

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
        exe_user: Map.get(session, "exe_user"),
        writer?: writer?(session)
      )

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "save",
        %{"content" => content},
        %{assigns: %{writer?: true, path: path}} = socket
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

  defp writer?(%{"authenticated" => true, "exe_user" => %{"email" => email}}),
    do: Writers.authorized?(email)

  defp writer?(_session), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-stone-50 text-stone-950">
      <main class="mx-auto flex min-h-screen w-full max-w-4xl flex-col gap-5 px-5 py-6 sm:px-8">
        <header class="flex flex-col gap-3 border-b border-stone-200 pb-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Synopticon</h1>
            <p class="mt-1 text-sm text-stone-600">If text exists, it is already out there.</p>
          </div>

          <div id="login-bar" class="text-sm text-stone-600 sm:text-right">
            <a :if={!@authenticated} class="underline underline-offset-4" href="/login">Login with exe</a>
            <span :if={@authenticated and @writer?}>authenticated as {@exe_user["email"]}</span>
            <span :if={@authenticated and !@writer?}>authenticated as {@exe_user["email"]} (read only)</span>
          </div>
        </header>

        <div class="flex flex-wrap items-center justify-between gap-2 text-xs uppercase tracking-wide text-stone-500">
          <span>Document {@path}</span>
          <span :if={@writer?}>live editing</span>
          <span :if={!@writer?}>readonly live view</span>
        </div>

        <.form
          :if={@writer?}
          for={%{}}
          as={:editor}
          id="editor-form"
          phx-change="save"
          class="flex flex-1"
        >
          <textarea
            name="content"
            class="min-h-[70vh] flex-1 resize-none rounded-xl border border-stone-200 bg-white p-5 text-lg leading-8 shadow-sm outline-none focus:border-stone-400 focus:ring-2 focus:ring-stone-200"
          ><%= @content %></textarea>
        </.form>

        <textarea
          :if={!@writer?}
          name="content"
          readonly="readonly"
          class="min-h-[70vh] flex-1 resize-none rounded-xl border border-stone-200 bg-white p-5 text-lg leading-8 shadow-sm outline-none"
        ><%= @content %></textarea>
      </main>
    </div>
    """
  end
end
