defmodule UnfinalWeb.ClaimLive do
  use UnfinalWeb, :live_view

  alias Unfinal.NamespaceStore

  @impl true
  def mount(_params, session, socket) do
    with %{"authenticated" => true, "user" => %{"id" => user_id} = user} <- session do
      {:ok,
       assign(socket,
         user: user,
         claimed_namespace: NamespaceStore.namespace_for_user_id(user_id),
         namespace: "",
         message: nil,
         error: nil
       )}
    else
      _session ->
        {:ok, redirect(socket, to: ~p"/login?return_to=/claim")}
    end
  end

  @impl true
  def handle_event("validate", %{"claim" => %{"namespace" => namespace}}, socket) do
    {:noreply, assign_validation(socket, namespace)}
  end

  def handle_event("claim", %{"claim" => %{"namespace" => namespace}}, socket) do
    namespace = String.trim(namespace)

    case NamespaceStore.claim(namespace, socket.assigns.user) do
      :ok ->
        {:noreply, redirect(socket, to: "/n/#{namespace}")}

      {:error, :invalid} ->
        {:noreply,
         assign(socket,
           namespace: namespace,
           error: invalid_namespace_message(),
           message: nil
         )}

      {:error, :taken} ->
        {:noreply,
         assign(socket,
           namespace: namespace,
           error: "That namespace is already taken.",
           message: nil
         )}

      {:error, :already_claimed} ->
        claimed = NamespaceStore.namespace_for_user_id(socket.assigns.user["id"])
        {:noreply, assign(socket, claimed_namespace: claimed, error: nil, message: nil)}
    end
  end

  defp assign_validation(socket, namespace) do
    namespace = String.trim(namespace)

    cond do
      namespace == "" ->
        assign(socket, namespace: namespace, error: nil, message: nil)

      not NamespaceStore.valid_namespace?(namespace) ->
        assign(socket,
          namespace: namespace,
          error: invalid_namespace_message(),
          message: nil
        )

      NamespaceStore.taken?(namespace) ->
        assign(socket,
          namespace: namespace,
          error: "That namespace is already taken.",
          message: nil
        )

      true ->
        assign(socket, namespace: namespace, error: nil, message: "Available.")
    end
  end

  defp invalid_namespace_message,
    do: "Use lowercase letters, numbers, and hyphens. Do not start or end with a hyphen."

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-6 bg-stone-50 p-6 text-stone-950">
      <h1 class="text-3xl font-semibold tracking-tight">Claim your page</h1>

      <div :if={@claimed_namespace} class="rounded border border-stone-200 bg-white p-4">
        You already claimed <a class="underline underline-offset-4" href={"/n/#{@claimed_namespace}"}>/n/{@claimed_namespace}</a>.
      </div>

      <.form
        :if={!@claimed_namespace}
        for={%{}}
        as={:claim}
        id="claim-form"
        phx-change="validate"
        phx-submit="claim"
        class="flex flex-col gap-3"
      >
        <label class="text-sm font-medium" for="claim_namespace">Namespace</label>
        <input
          id="claim_namespace"
          name="claim[namespace]"
          value={@namespace}
          pattern="[a-z0-9][a-z0-9-]*[a-z0-9]|[a-z0-9]"
          required
          autocomplete="off"
          class="border border-stone-200 bg-white p-3 outline-none focus:border-stone-400 focus:ring-2 focus:ring-stone-200"
        />
        <p :if={@error} class="text-sm text-red-700">{@error}</p>
        <p :if={@message} class="text-sm text-green-700">{@message}</p>
        <button class="border border-stone-950 bg-stone-950 px-4 py-2 text-white" type="submit">Claim</button>
      </.form>
    </main>
    """
  end
end
