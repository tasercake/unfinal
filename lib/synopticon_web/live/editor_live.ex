defmodule SynopticonWeb.EditorLive do
  use SynopticonWeb, :live_view

  alias Synopticon.ContentStore
  alias Synopticon.Writers

  @blank_page_words ~w(
    amber apple ash autumn bird blue brook cedar cloud copper dawn ember fern field
    fox garden glow green harbor hill leaf meadow moon moss night ocean pine quiet
    rain river sage sky stone sun swift valley violet willow wind winter
  )

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
        writer?: writer?(session),
        blank_page_paths: blank_page_paths(path, session)
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

  defp blank_page_paths("/", session) do
    if writer?(session) do
      blank_page_path_generator().()
    else
      []
    end
  end

  defp blank_page_paths(_path, _session), do: []

  defp blank_page_path_generator do
    Application.get_env(
      :synopticon,
      :blank_page_path_generator,
      &__MODULE__.random_blank_page_paths/0
    )
  end

  def random_blank_page_paths do
    @blank_page_words
    |> Enum.take_random(10)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [first, second] -> "/#{first}#{second}" end)
  end

  def blank_page_words, do: @blank_page_words

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-dvh min-h-dvh overflow-hidden bg-stone-50 text-center text-stone-950 [font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe_UI',sans-serif]">
      <div class="mx-auto grid h-full min-h-0 w-full max-w-[76rem] grid-cols-1 gap-4 px-4 lg:grid-cols-[12rem_minmax(0,52rem)_12rem]">
        <div class="hidden lg:block" aria-hidden="true"></div>

        <main class="flex h-full min-h-0 w-full max-w-[52rem] flex-col gap-4 py-4 sm:py-6">
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
            <span :if={@authenticated} class="inline-flex items-center gap-1 whitespace-nowrap">
              <span>Logged in as {@exe_user["email"]} •</span>
              <a
                id="logout-link"
                class="underline underline-offset-4"
                href={~p"/logout?return_to=#{@path}"}
              >
                Logout
              </a>
            </span>
          </footer>
        </main>

        <aside
          :if={@blank_page_paths != []}
          id="blank-page-links"
          class="hidden py-6 text-left text-sm text-stone-600 lg:block"
        >
          <h2 class="mb-3 text-xs font-semibold uppercase tracking-wide text-stone-500">
            Blank pages
          </h2>
          <nav aria-label="Blank pages">
            <ul class="space-y-2">
              <li :for={path <- @blank_page_paths}>
                <a class="underline underline-offset-4 hover:text-stone-950" href={path}>{path}</a>
              </li>
            </ul>
          </nav>
        </aside>
      </div>
    </div>
    """
  end
end
