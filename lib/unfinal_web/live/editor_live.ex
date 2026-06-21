defmodule UnfinalWeb.EditorLive do
  use UnfinalWeb, :live_view

  alias Unfinal.ContentStore
  alias Unfinal.NamespaceStore
  alias Unfinal.Writers

  @blank_page_words ~w(
    amber apple ash autumn bird blue brook cedar cloud copper dawn ember fern field
    fox garden glow green harbor hill leaf meadow moon moss night ocean pine quiet
    rain river sage sky stone sun swift valley violet willow wind winter
  )

  @impl true
  def mount(params, session, socket) do
    path = url_path(params)
    storage_path = storage_path(params)

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Unfinal.PubSub, ContentStore.topic(storage_path))

    claimed_namespace = claimed_namespace(session)
    writer? = writer?(path, session, claimed_namespace)

    document = ContentStore.get(storage_path)

    socket =
      assign(socket,
        path: path,
        storage_path: storage_path,
        content: document.content,
        etag: document.etag,
        revision: document.revision,
        authenticated: Map.get(session, "authenticated", false),
        user: Map.get(session, "user"),
        claimed_namespace: claimed_namespace,
        writer?: writer?,
        show_claim_link?: show_claim_link?(session, claimed_namespace),
        blank_page_paths:
          if(connected?(socket), do: blank_page_paths(path, session, claimed_namespace), else: [])
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
            storage_path: storage_path,
            etag: base_etag,
            revision: base_revision
          }
        } = socket
      ) do
    case ContentStore.put(storage_path, content, base_etag, base_revision) do
      {:ok, document} ->
        {:noreply,
         assign(socket,
           content: document.content,
           etag: document.etag,
           revision: document.revision
         )}

      {:stale, document} ->
        {:noreply,
         assign(socket,
           content: document.content,
           etag: document.etag,
           revision: document.revision
         )}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:content_updated, storage_path, %{revision: incoming_revision}},
        %{assigns: %{storage_path: storage_path, revision: current_revision}} = socket
      )
      when incoming_revision <= current_revision do
    {:noreply, socket}
  end

  def handle_info(
        {:content_updated, storage_path, %{etag: _etag, revision: _revision}},
        %{assigns: %{storage_path: storage_path}} = socket
      ) do
    document = ContentStore.get(storage_path)

    {:noreply,
     assign(socket,
       content: document.content,
       etag: document.etag,
       revision: document.revision
     )}
  end

  defp url_path(%{"path" => parts}), do: "/n/" <> Enum.join(parts, "/")
  defp url_path(_params), do: "/n"

  defp storage_path(%{"path" => parts}), do: "/" <> Enum.join(parts, "/")
  defp storage_path(_params), do: "/"

  defp writer?("/n", session, _claimed_namespace), do: superuser?(session)

  defp writer?(path, _session, claimed_namespace) when is_binary(claimed_namespace) do
    path == "/n/#{claimed_namespace}" or String.starts_with?(path, "/n/#{claimed_namespace}/")
  end

  defp writer?(_path, _session, _claimed_namespace), do: false

  defp superuser?(%{"authenticated" => true, "user" => %{"email" => email}}),
    do: Writers.authorized?(email)

  defp superuser?(_session), do: false

  defp claimed_namespace(%{"authenticated" => true, "user" => %{"email" => email}}),
    do: NamespaceStore.namespace_for_email(email)

  defp claimed_namespace(_session), do: nil

  defp show_claim_link?(%{"authenticated" => true}, nil), do: true
  defp show_claim_link?(_session, _claimed_namespace), do: false

  defp blank_page_paths(path, session, claimed_namespace) when is_binary(claimed_namespace) do
    if path == "/n/#{claimed_namespace}" and Map.get(session, "authenticated", false) do
      Enum.map(blank_page_path_generator().(), &namespace_path(claimed_namespace, &1))
    else
      []
    end
  end

  defp blank_page_paths(_path, _session, _claimed_namespace), do: []

  defp namespace_path(namespace, path) do
    suffix = path |> String.trim() |> String.trim_leading("/")
    "/n/#{namespace}/#{suffix}"
  end

  defp display_blank_page_path("/n" <> path), do: path
  defp display_blank_page_path(path), do: path

  defp blank_page_path_generator do
    Application.get_env(
      :unfinal,
      :blank_page_path_generator,
      &__MODULE__.random_blank_page_paths/0
    )
  end

  def random_blank_page_paths do
    @blank_page_words
    |> Enum.take_random(10)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [first, second] -> "#{first}#{second}" end)
  end

  def blank_page_words, do: @blank_page_words

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-dvh min-h-dvh overflow-hidden bg-stone-50 text-center text-stone-950 [font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe_UI',sans-serif]">
      <div class="mx-auto grid h-full min-h-0 w-full max-w-[76rem] grid-cols-1 gap-4 px-4 lg:grid-cols-[12rem_minmax(0,52rem)_12rem]">
        <div class="hidden lg:block" aria-hidden="true"></div>

        <main class="flex h-full min-h-0 w-full max-w-[52rem] flex-col gap-4 justify-self-center py-4 sm:py-6">
          <header class="shrink-0 border-b border-stone-200 pb-4">
            <h1 class="text-3xl font-semibold tracking-tight">Unfinal</h1>
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
            >Login to edit</a>
            <span :if={@authenticated} class="inline-flex items-center gap-1 whitespace-nowrap">
              <span>Logged in as {@user["email"]} •</span>
              <a
                id="logout-link"
                class="underline underline-offset-4"
                href={~p"/logout?return_to=#{@path}"}
              >Logout</a>
            </span>
          </footer>
        </main>

        <aside
          :if={@show_claim_link?}
          id="claim-page-link"
          class="hidden py-6 text-left text-sm text-stone-600 lg:block"
        >
          <a class="underline underline-offset-4 hover:text-stone-950" href={~p"/claim"}>Claim your page</a>
        </aside>

        <aside
          :if={@blank_page_paths != []}
          id="blank-page-links"
          class="hidden py-6 text-left text-sm text-stone-600 lg:block"
        >
          <h2 class="mb-3 text-xs font-semibold uppercase tracking-wide text-stone-500">
            Write somewhere new
          </h2>
          <nav aria-label="Blank pages">
            <ul class="space-y-2">
              <li :for={path <- @blank_page_paths}>
                <a class="underline underline-offset-4 hover:text-stone-950" href={path}>
                  {display_blank_page_path(path)}
                </a>
              </li>
            </ul>
          </nav>
        </aside>
      </div>
    </div>
    """
  end
end
