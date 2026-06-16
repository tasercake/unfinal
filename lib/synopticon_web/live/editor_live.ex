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
    <div class="h-dvh min-h-dvh overflow-hidden bg-stone-50 text-center text-stone-950 [font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe_UI',sans-serif]">
      <main class="mx-auto flex h-full min-h-0 w-full max-w-[52rem] flex-col gap-4 px-3 py-4 sm:px-8 sm:py-6 md:px-16 lg:px-24">
        <header class="shrink-0 border-b border-stone-200 pb-4">
          <h1 class="text-3xl font-semibold tracking-tight">Synopticon</h1>
        </header>

        <div class="flex shrink-0 flex-wrap items-center justify-center gap-x-4 gap-y-1 text-xs uppercase tracking-wide text-stone-500">
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
          class="flex min-h-0 flex-1 overflow-hidden"
        >
          <textarea
            name="content"
            class="h-full min-h-0 flex-1 resize-none overflow-y-auto rounded-xl border border-stone-200 bg-white p-5 text-left text-lg leading-8 shadow-sm outline-none focus:border-stone-400 focus:ring-2 focus:ring-stone-200"
          ><%= @content %></textarea>
        </.form>

        <textarea
          :if={!@writer?}
          name="content"
          readonly="readonly"
          class="h-full min-h-0 flex-1 resize-none overflow-y-auto rounded-xl border border-stone-200 bg-white p-5 text-left text-lg leading-8 shadow-sm outline-none"
        ><%= @content %></textarea>

        <footer id="login-bar" class="shrink-0 border-t border-stone-200 pt-4 text-sm text-stone-600">
          <a :if={!@authenticated} class="underline underline-offset-4" href="/login">Login with exe</a>
          <span :if={@authenticated and @writer?}>authenticated as {@exe_user["email"]}</span>
          <span :if={@authenticated and !@writer?}>authenticated as {@exe_user["email"]} (read only)</span>
        </footer>
      </main>
    </div>
    """
  end
end
