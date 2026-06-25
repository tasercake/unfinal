defmodule UnfinalWeb.EditorLive do
  use UnfinalWeb, :live_view

  alias Unfinal.DocumentPath
  alias Unfinal.Documents
  alias Unfinal.NamespaceStore
  alias Unfinal.PageIndex
  alias Unfinal.Writers

  @impl true
  def mount(params, session, socket) do
    segments = path_segments(params)

    unless DocumentPath.valid_segments?(segments) do
      raise Phoenix.Router.NoRouteError,
        conn: socket.private.connect_info,
        router: UnfinalWeb.Router
    end

    path = url_path(segments)
    storage_path = storage_path(segments)

    claimed_namespace = claimed_namespace(session)
    viewed_namespace = viewed_namespace(segments)
    writer? = writer?(segments, session, claimed_namespace)

    if connected?(socket) and not writer?,
      do: Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic(storage_path))

    document = Documents.get(storage_path)

    socket =
      assign(socket,
        path: path,
        storage_path: storage_path,
        content: document.content,
        saved_content: document.content,
        etag: document.etag,
        revision: document.revision,
        authenticated: Map.get(session, "authenticated", false),
        user: Map.get(session, "user"),
        claimed_namespace: claimed_namespace,
        viewed_namespace: viewed_namespace,
        writer?: writer?,
        show_claim_link?: show_claim_link?(session, claimed_namespace),
        show_pages_nav?: show_pages_nav?(segments),
        root_page_path: root_page_path(segments, path, true),
        page_paths: page_paths(segments, path)
      )

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "save",
        %{"content" => content},
        %{
          assigns: %{
            writer?: true,
            storage_path: storage_path
          }
        } = socket
      ) do
    :ok = Documents.queue_put(storage_path, content)
    maybe_index_page(Map.get(socket.assigns, :claimed_namespace), storage_path)
    {:noreply, socket}
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event(
        "open_new_page",
        %{"path" => path},
        %{assigns: %{claimed_namespace: namespace, viewed_namespace: namespace}} = socket
      )
      when is_binary(namespace) do
    slug = path |> String.trim() |> String.trim_leading("/")

    if DocumentPath.valid_segments?([namespace, slug]) do
      {:noreply, push_navigate(socket, to: namespace_path(namespace, slug))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_new_page", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:content_updated, storage_path, %{content: "", etag: nil, revision: 0}},
        %{assigns: %{storage_path: storage_path}} = socket
      ) do
    {:noreply, assign(socket, content: "", etag: nil, revision: 0)}
  end

  def handle_info(
        {:content_updated, storage_path, %{revision: incoming_revision}},
        %{assigns: %{storage_path: storage_path, revision: current_revision}} = socket
      )
      when incoming_revision <= current_revision do
    {:noreply, socket}
  end

  def handle_info(
        {:content_updated, storage_path, %{content: content, etag: etag, revision: revision}},
        %{assigns: %{storage_path: storage_path}} = socket
      ) do
    {:noreply,
     assign(socket,
       content: content,
       etag: etag,
       revision: revision
     )}
  end

  defp path_segments(%{"path" => parts}), do: parts
  defp path_segments(_params), do: []

  defp url_path([]), do: "/n"
  defp url_path(parts), do: "/n/" <> Enum.join(parts, "/")

  defp storage_path([]), do: "/"
  defp storage_path(parts), do: "/" <> Enum.join(parts, "/")

  defp writer?([], session, _claimed_namespace), do: superuser?(session)

  defp writer?([namespace | _rest], _session, claimed_namespace)
       when is_binary(claimed_namespace),
       do: namespace == claimed_namespace

  defp writer?(_segments, _session, _claimed_namespace), do: false

  defp superuser?(%{"authenticated" => true, "user" => %{"email" => email}}),
    do: Writers.authorized?(email)

  defp superuser?(_session), do: false

  defp claimed_namespace(%{"authenticated" => true, "user" => %{"email" => email}}),
    do: NamespaceStore.namespace_for_email(email)

  defp claimed_namespace(_session), do: nil

  defp show_claim_link?(%{"authenticated" => true}, nil), do: true
  defp show_claim_link?(_session, _claimed_namespace), do: false

  defp show_pages_nav?([_namespace | _rest]), do: true
  defp show_pages_nav?([]), do: false

  defp viewed_namespace([namespace | _rest]), do: namespace
  defp viewed_namespace([]), do: nil

  defp root_page_path([namespace], _current_path, _connected?), do: namespace_path(namespace, "/")

  defp root_page_path([namespace | _rest], _current_path, true) do
    if Enum.any?(PageIndex.list(namespace), &(&1.path == "/")) do
      namespace_path(namespace, "/")
    end
  end

  defp root_page_path(_segments, _current_path, _connected?), do: nil

  defp page_paths([namespace | _rest], _current_path) do
    root_path = namespace_path(namespace, "/")

    namespace
    |> PageIndex.list()
    |> Enum.map(&namespace_path(namespace, &1.path))
    |> Enum.reject(&(&1 == root_path))
  end

  defp page_paths(_segments, _current_path), do: []

  defp namespace_path(namespace, "/"), do: "/n/#{namespace}"

  defp namespace_path(namespace, path) do
    suffix = path |> String.trim() |> String.trim_leading("/")
    "/n/#{namespace}/#{suffix}"
  end

  defp display_page_path("/n" <> path), do: path
  defp display_page_path(path), do: path

  defp maybe_index_page(namespace, "/" <> path) when is_binary(namespace) do
    case String.split(path, "/", parts: 2) do
      [^namespace] ->
        PageIndex.upsert(namespace, "/", DateTime.utc_now())

      [^namespace, relative] when relative != "" ->
        PageIndex.upsert(namespace, "/" <> relative, DateTime.utc_now())

      _other ->
        :ok
    end
  end

  defp maybe_index_page(_namespace, _storage_path), do: :ok

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-dvh min-h-dvh overflow-hidden bg-stone-50 text-stone-950 [font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe_UI',sans-serif]">
      <div class="grid h-full min-h-0 grid-rows-[auto_minmax(0,1fr)] overflow-hidden lg:grid-cols-[15rem_minmax(0,1fr)] lg:grid-rows-1">
        <aside class="flex max-h-72 min-h-0 flex-col border-r border-stone-200/70 bg-stone-100 px-4 py-4 text-left lg:max-h-none">
          <h1 class="text-[15px] font-semibold tracking-tight">Unfinal</h1>

          <nav :if={@show_pages_nav?} id="pages-nav" class="mt-7 text-sm" aria-label="Pages">
            <h2 class="mb-2 text-[11px] font-medium uppercase tracking-[0.14em] text-stone-400">
              Pages
            </h2>
            <div class="space-y-1 text-stone-500">
              <a
                :if={@root_page_path}
                class={[
                  "block rounded-lg px-3 py-1.5 hover:bg-white/50 hover:text-stone-950",
                  @root_page_path == @path &&
                    "bg-white/70 py-2 font-medium text-stone-950 shadow-sm shadow-stone-200/50"
                ]}
                href={@root_page_path}
              >
                {display_page_path(@root_page_path)}
              </a>

              <div
                :if={
                  @root_page_path &&
                    ((is_binary(@claimed_namespace) and @viewed_namespace == @claimed_namespace) or
                       @page_paths != [])
                }
                class="mx-3 my-2 border-t border-stone-200/80"
              />

              <.form
                :if={is_binary(@claimed_namespace) and @viewed_namespace == @claimed_namespace}
                for={%{}}
                id="new-page-form"
                phx-submit="open_new_page"
              >
                <label class="sr-only" for="new-page-path">New page path</label>
                <div class="group flex items-center rounded-lg px-3 py-1.5 text-stone-400 hover:bg-white/50 focus-within:bg-white/70 focus-within:text-stone-950 focus-within:shadow-sm focus-within:shadow-stone-200/50">
                  <span class="mr-1 text-stone-300 group-focus-within:text-stone-400">+</span>
                  <span class="text-stone-300 group-focus-within:text-stone-400">/{@claimed_namespace}/</span>
                  <input
                    id="new-page-path"
                    name="path"
                    class="min-w-0 flex-1 bg-transparent outline-none placeholder:text-stone-300"
                    placeholder="new-page"
                  />
                </div>
                <button class="sr-only" type="submit">Open new page</button>
              </.form>

              <a
                :if={@path != @root_page_path and @path not in @page_paths}
                class="block rounded-lg bg-white/70 px-3 py-2 font-medium text-stone-950 shadow-sm shadow-stone-200/50"
                href={@path}
              >
                {display_page_path(@path)}
              </a>

              <a
                :for={path <- @page_paths}
                class={[
                  "block rounded-lg px-3 py-1.5 hover:bg-white/50 hover:text-stone-950",
                  path == @path &&
                    "bg-white/70 py-2 font-medium text-stone-950 shadow-sm shadow-stone-200/50"
                ]}
                href={path}
              >
                {display_page_path(path)}
              </a>
            </div>
          </nav>

          <section id="login-bar" class="mt-auto shrink-0 border-t border-stone-200/80 pt-4 text-sm">
            <div class="mb-2 text-[11px] font-medium uppercase tracking-[0.14em] text-stone-400">
              Account
            </div>
            <a
              :if={@show_claim_link?}
              id="claim-page-link"
              class="mb-3 block rounded-lg bg-white/70 px-3 py-2 font-medium text-stone-900 shadow-sm shadow-stone-200/50 ring-1 ring-stone-200/60 hover:bg-white"
              href={~p"/claim"}
            >Claim your page</a>
            <a
              :if={!@authenticated}
              class="underline underline-offset-4"
              href={~p"/login?return_to=#{@path}"}
            >Login to edit</a>
            <div :if={@authenticated}>
              <p class="truncate text-stone-700">{@user["email"]}</p>
              <a
                id="logout-link"
                class="mt-1 inline-block text-stone-500 underline underline-offset-4 hover:text-stone-950"
                href={~p"/logout?return_to=#{@path}"}
              >Logout</a>
            </div>
          </section>
        </aside>

        <main class="flex min-h-0 min-w-0 flex-col">
          <header class="relative flex h-11 shrink-0 items-center px-6 text-xs text-stone-400">
            <div class="truncate">{@path}</div>
            <div class="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 text-[11px] uppercase tracking-[0.18em] text-stone-300">
              <span :if={@writer?}>Live</span>
              <span :if={!@writer?}>Read only</span>
            </div>
          </header>

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
              class="h-full min-h-0 w-full flex-1 resize-none overflow-y-auto border-0 bg-transparent px-[clamp(2rem,7vw,7rem)] py-10 text-left text-[22px] leading-10 outline-none placeholder:text-stone-300"
            ><%= @content %></textarea>
          </.form>

          <article
            :if={!@writer?}
            id="readonly-document"
            class="h-full min-h-0 flex-1 overflow-y-auto whitespace-pre-wrap bg-transparent px-[clamp(2rem,7vw,7rem)] py-10 text-left text-[22px] leading-10"
            phx-no-format
          ><%= @content %></article>
        </main>
      </div>
    </div>
    """
  end
end
