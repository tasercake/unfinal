defmodule UnfinalWeb.LiveLive do
  use UnfinalWeb, :live_view

  alias Unfinal.Documents
  alias Unfinal.NamespaceStore
  alias Unfinal.SqliteDocuments
  alias UnfinalWeb.Layouts
  alias UnfinalWeb.Presence

  @topic "editing"

  @impl true
  def mount(_params, session, socket) do
    authenticated = Map.get(session, "authenticated", false)
    user = Map.get(session, "user")
    claimed_namespace = claimed_namespace(session)
    show_claim_link? = authenticated and is_nil(claimed_namespace)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unfinal.PubSub, @topic)
      Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.edit_topic())
      active_paths = active_paths()
      Enum.each(active_paths, &Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic(&1)))

      recent_edits = seed_recent_edits()
      recent_paths = Map.keys(recent_edits) -- MapSet.to_list(active_paths)
      excerpts = excerpts(MapSet.union(active_paths, MapSet.new(recent_paths)), %{})

      {:ok,
       assign(socket,
         active_paths: active_paths,
         sorted_paths: sorted_paths(),
         excerpts: excerpts,
         recent_edits: recent_edits,
         authenticated: authenticated,
         user: user,
         claimed_namespace: claimed_namespace,
         show_claim_link?: show_claim_link?,
         mobile_menu_open: false
       )}
    else
      {:ok,
       assign(socket,
         active_paths: MapSet.new(),
         sorted_paths: [],
         excerpts: %{},
         recent_edits: %{},
         authenticated: authenticated,
         user: user,
         claimed_namespace: claimed_namespace,
         show_claim_link?: show_claim_link?,
         mobile_menu_open: false
       )}
    end
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    active_paths = active_paths()
    previous_paths = socket.assigns.active_paths

    for path <- MapSet.difference(active_paths, previous_paths) do
      Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic(path))
    end

    for path <- MapSet.difference(previous_paths, active_paths) do
      Phoenix.PubSub.unsubscribe(Unfinal.PubSub, Documents.topic(path))
    end

    excerpts = excerpts(active_paths, socket.assigns.excerpts)

    {:noreply,
     assign(socket, active_paths: active_paths, sorted_paths: sorted_paths(), excerpts: excerpts)}
  end

  def handle_info({:content_updated, path, %{content: content}}, socket) do
    if MapSet.member?(socket.assigns.active_paths, path) do
      {:noreply, update(socket, :excerpts, &Map.put(&1, path, content))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:edit, path, timestamp}, socket) do
    socket = update(socket, :recent_edits, &Map.put(&1, path, timestamp))

    socket =
      if not MapSet.member?(socket.assigns.active_paths, path) and
           not Map.has_key?(socket.assigns.excerpts, path) do
        update(socket, :excerpts, &Map.put(&1, path, Documents.get(path).content))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, mobile_menu_open: !socket.assigns.mobile_menu_open)}
  end

  def handle_event("close_mobile_menu", _params, socket) do
    {:noreply, assign(socket, mobile_menu_open: false)}
  end

  defp claimed_namespace(%{"authenticated" => true, "user" => %{"id" => user_id}}),
    do: NamespaceStore.namespace_for_user_id(user_id)

  defp claimed_namespace(_session), do: nil

  defp seed_recent_edits do
    SqliteDocuments.recent_edits(20)
    |> Enum.map(fn %{path: path, updated_at: updated_at} ->
      {path, parse_timestamp(updated_at)}
    end)
    |> Map.new()
  end

  defp parse_timestamp(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp active_paths do
    @topic |> Presence.list() |> Map.keys() |> MapSet.new()
  end

  defp sorted_paths do
    @topic
    |> Presence.list()
    |> Enum.map(fn {_key, %{metas: [meta | _]}} -> {meta.path, meta.joined_at} end)
    |> Enum.reject(fn {path, _ts} -> root_namespace_path?(path) end)
    |> Enum.sort_by(fn {_, ts} -> -ts end)
  end

  defp excerpts(active_paths, current_excerpts) do
    active_paths
    |> Enum.map(fn path -> {path, initial_content(path, current_excerpts)} end)
    |> Map.new()
  end

  defp initial_content(path, excerpts) do
    Map.get_lazy(excerpts, path, fn -> Documents.get(path).content end)
  end

  defp excerpt(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp excerpt(_content), do: ""

  defp document_href("/" <> path), do: "/n/" <> path
  defp document_href(_path), do: "/n"

  defp root_namespace_path?("/"), do: true
  defp root_namespace_path?("/__root__" <> _rest), do: true
  defp root_namespace_path?(_path), do: false

  defp time_ago(timestamp) when is_integer(timestamp) do
    seconds = System.system_time(:second) - timestamp

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86400)}d ago"
    end
  end

  defp visible_recent(recent_edits, active_paths, excerpts, limit \\ 10) do
    recent_edits
    |> Enum.reject(fn {path, _ts} -> MapSet.member?(active_paths, path) end)
    |> Enum.reject(fn {path, _ts} -> root_namespace_path?(path) end)
    |> Enum.reject(fn {path, _ts} -> excerpt(Map.get(excerpts, path, "")) == "" end)
    |> Enum.sort_by(fn {_, ts} -> -ts end)
    |> Enum.take(limit)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-dvh min-h-dvh overflow-hidden bg-stone-50 text-stone-950 [font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe_UI',sans-serif]">
      <div class="grid h-full min-h-0 grid-rows-[auto_minmax(0,1fr)] overflow-hidden lg:grid-cols-[15rem_minmax(0,1fr)] lg:grid-rows-1">
        <Layouts.sidebar
          current_path="/live"
          authenticated={@authenticated}
          user={@user}
          show_claim_link?={@show_claim_link?}
          claimed_namespace={@claimed_namespace}
          mobile_menu_open={@mobile_menu_open}
        />

        <main class="flex min-h-0 min-w-0 flex-col overflow-y-auto">
          <section class="mx-auto w-full max-w-2xl px-6 py-12">
            <header class="mb-8">
              <h1 class="text-3xl font-semibold tracking-tight">Live now</h1>
              <p class="mt-2 text-sm text-stone-500">Spy on works in progress ;)</p>
            </header>

            <div
              :if={Enum.empty?(@sorted_paths)}
              class="rounded-2xl border border-stone-200 bg-white px-5 py-6 text-sm text-stone-500 shadow-sm shadow-stone-200/40"
            >
              Nothing being edited right now.
            </div>

            <div :if={!Enum.empty?(@sorted_paths)} class="space-y-3">
              <a
                :for={{path, _joined_at} <- @sorted_paths}
                href={document_href(path)}
                class="relative block rounded-2xl border border-stone-200 bg-white px-5 py-4 shadow-sm shadow-stone-200/40 transition hover:border-stone-300 hover:shadow-md"
              >
                <span class="absolute top-3 right-4 text-[11px] font-medium uppercase tracking-wider text-green-600">live</span>
                <div class="truncate pr-12 text-sm font-semibold text-stone-900">{path}</div>
                <p
                  :if={excerpt(Map.get(@excerpts, path, "")) != ""}
                  class="mt-2 text-sm leading-6 text-stone-600"
                >
                  {excerpt(Map.get(@excerpts, path, ""))}
                </p>
                <p
                  :if={excerpt(Map.get(@excerpts, path, "")) == ""}
                  class="mt-2 text-sm italic leading-6 text-stone-400"
                >
                  waiting for the first word...
                </p>
              </a>
            </div>

            <% visible_recent = visible_recent(@recent_edits, @active_paths, @excerpts) %>

            <div :if={visible_recent != []}>
              <hr class="my-8 border-stone-200" />
              <div class="mt-4 space-y-3">
                <a
                  :for={{path, timestamp} <- visible_recent}
                  href={document_href(path)}
                  class="relative block rounded-2xl border border-stone-200 bg-white px-5 py-4 shadow-sm shadow-stone-200/40 transition hover:border-stone-300 hover:shadow-md"
                >
                  <span class="absolute top-3 right-4 text-[11px] text-stone-400">{time_ago(timestamp)}</span>
                  <div class="truncate pr-16 text-sm font-semibold text-stone-900">{path}</div>
                  <p
                    :if={excerpt(Map.get(@excerpts, path, "")) != ""}
                    class="mt-2 text-sm leading-6 text-stone-600"
                  >
                    {excerpt(Map.get(@excerpts, path, ""))}
                  </p>
                </a>
              </div>
            </div>
          </section>
        </main>
      </div>
    </div>
    """
  end
end
