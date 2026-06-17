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
      <main class="mx-auto flex h-full min-h-0 w-full max-w-[52rem] flex-col gap-4 py-4 sm:py-6">
        <header class="shrink-0 border-b border-stone-200 pb-4">
          <h1 class="text-3xl font-semibold tracking-tight">Synopticon</h1>
        </header>

        <div class="flex shrink-0 flex-wrap items-center justify-center gap-x-4 gap-y-1 text-xs uppercase tracking-wide text-stone-500">
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
            class="h-full min-h-0 flex-1 resize-none overflow-y-auto border border-stone-200 bg-white p-5 text-left text-lg leading-8 shadow-sm outline-none focus:border-stone-400 focus:ring-2 focus:ring-stone-200"
          ><%= @content %></textarea>
        </.form>

        <article
          :if={!@writer?}
          id="readonly-document"
          class="h-full min-h-0 flex-1 overflow-y-auto whitespace-pre-wrap border border-stone-200 bg-white p-5 text-left text-lg leading-8 shadow-sm"
          phx-no-format
        ><%= @content %></article>

        <footer id="login-bar" class="shrink-0 pt-4 text-sm text-stone-600">
          <a
            :if={!@authenticated}
            class="underline underline-offset-4"
            href={~p"/login?return_to=#{@path}"}
          >
            Login to edit
          </a>
          <span :if={@authenticated}>
            Logged in as {@exe_user["email"]} •
            <form id="exe-logout-form" action="/__exe.dev/logout" method="post" class="inline">
              <button type="submit" class="underline underline-offset-4">Logout</button>
            </form>
          </span>
        </footer>
      </main>
    </div>
    """
  end
end
