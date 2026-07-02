defmodule UnfinalWeb.LiveLive do
  use UnfinalWeb, :live_view

  alias Unfinal.Documents
  alias UnfinalWeb.Presence

  @topic "editing"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Unfinal.PubSub, @topic)
      active_paths = active_paths()
      Enum.each(active_paths, &Phoenix.PubSub.subscribe(Unfinal.PubSub, Documents.topic(&1)))

      {:ok, assign(socket, active_paths: active_paths, excerpts: excerpts(active_paths, %{}))}
    else
      {:ok, assign(socket, active_paths: MapSet.new(), excerpts: %{})}
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

    {:noreply, assign(socket, active_paths: active_paths, excerpts: excerpts)}
  end

  def handle_info({:content_updated, path, %{content: content}}, socket) do
    if MapSet.member?(socket.assigns.active_paths, path) do
      {:noreply, update(socket, :excerpts, &Map.put(&1, path, content))}
    else
      {:noreply, socket}
    end
  end

  defp active_paths do
    @topic |> Presence.list() |> Map.keys() |> MapSet.new()
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

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-stone-50 px-6 py-12 text-stone-950 [font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe_UI',sans-serif]">
      <section class="mx-auto max-w-2xl">
        <header class="mb-8">
          <a href="/" class="text-sm font-semibold tracking-tight hover:opacity-80">Unfinal</a>
          <h1 class="mt-8 text-3xl font-semibold tracking-tight">Live now</h1>
          <p class="mt-2 text-sm text-stone-500">Documents being edited right now.</p>
        </header>

        <div :if={Enum.empty?(@active_paths)} class="rounded-2xl border border-stone-200 bg-white px-5 py-6 text-sm text-stone-500 shadow-sm shadow-stone-200/40">
          Nothing being edited right now.
        </div>

        <div :if={!Enum.empty?(@active_paths)} class="space-y-3">
          <a
            :for={path <- Enum.sort(@active_paths)}
            href={document_href(path)}
            class="block rounded-2xl border border-stone-200 bg-white px-5 py-4 shadow-sm shadow-stone-200/40 transition hover:border-stone-300 hover:shadow-md"
          >
            <div class="truncate text-sm font-semibold text-stone-900">{path}</div>
            <p :if={excerpt(Map.get(@excerpts, path, "")) != ""} class="mt-2 text-sm leading-6 text-stone-600">
              {excerpt(Map.get(@excerpts, path, ""))}
            </p>
            <p :if={excerpt(Map.get(@excerpts, path, "")) == ""} class="mt-2 text-sm italic leading-6 text-stone-400">
              waiting for the first word...
            </p>
          </a>
        </div>
      </section>
    </main>
    """
  end
end
