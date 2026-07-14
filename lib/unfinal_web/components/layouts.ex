defmodule UnfinalWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use UnfinalWeb, :controller` and
  `use UnfinalWeb, :live_view`.
  """
  use UnfinalWeb, :html

  embed_templates "layouts/*"

  attr :current_path, :string, required: true
  attr :authenticated, :boolean, default: false
  attr :user, :map, default: nil
  attr :show_pages_nav?, :boolean, default: false
  attr :claimed_namespace, :string, default: nil
  attr :root_page_path, :string, default: nil
  attr :page_paths, :list, default: []
  attr :writer?, :boolean, default: false
  attr :show_claim_link?, :boolean, default: false
  attr :mobile_menu_open, :boolean, default: false
  slot :inner_block

  def sidebar(assigns) do
    ~H"""
    <aside
      id="sidebar"
      class="flex min-h-0 flex-col border-r border-stone-200/70 bg-stone-100 px-4 py-4 text-left lg:max-h-none lg:overflow-visible"
    >
      <div class="flex items-center justify-between">
        <a href="/" class="text-[15px] font-semibold tracking-tight hover:opacity-80">Unfinal</a>
        <button
          type="button"
          phx-click="toggle_mobile_menu"
          class="flex items-center justify-center rounded-md p-1.5 text-stone-500 hover:bg-stone-200/70 hover:text-stone-700 lg:hidden"
          aria-label={if(@mobile_menu_open, do: "Close menu", else: "Open menu")}
        >
          <.icon :if={!@mobile_menu_open} name="hero-bars-3" class="h-5 w-5" />
          <.icon :if={@mobile_menu_open} name="hero-x-mark" class="h-5 w-5" />
        </button>
      </div>

      <div
        id="mobile-nav-content"
        class="flex-col flex-1 min-h-0 lg:flex"
      >
        <nav :if={@show_pages_nav?} id="pages-nav" class="mt-7 text-sm" aria-label="Pages">
          <h2 class="mb-2 text-[11px] font-medium uppercase tracking-[0.14em] text-stone-400">
            Pages
          </h2>
          <div class="space-y-1 text-stone-500">
            <a
              :if={@root_page_path}
              class="block rounded-lg px-3 py-1.5 hover:bg-white/50 hover:text-stone-950"
              href={@root_page_path}
            >
              {display_page_path(@root_page_path)}
            </a>

            <div
              :if={@root_page_path and @page_paths != []}
              class="mx-3 my-2 border-t border-stone-200/80"
            />

            <a
              :for={path <- @page_paths}
              href={path}
              class="block rounded-lg px-3 py-1.5 hover:bg-white/50 hover:text-stone-950"
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
            href="/claim"
          >Claim your page</a>
          <a
            :if={!@authenticated}
            class="underline underline-offset-4"
            href="/login?return_to=#{@current_path}"
          >Login to edit</a>
          <div :if={@authenticated}>
            <p class="truncate text-stone-700">{@user["email"]}</p>
            <a
              :if={@claimed_namespace}
              class="mt-1 block text-stone-600 underline underline-offset-4 hover:text-stone-950"
              href="/n/#{@claimed_namespace}"
            >My notebook</a>
            <a
              :if={!@claimed_namespace}
              class="mt-1 block text-stone-600 underline underline-offset-4 hover:text-stone-950"
              href="/claim"
            >My notebook</a>
            <a
              id="logout-link"
              class="mt-1 inline-block text-stone-500 underline underline-offset-4 hover:text-stone-950"
              href="/logout?return_to=#{@current_path}"
            >Logout</a>
          </div>
        </section>
      </div>
    </aside>
    """
  end

  defp display_page_path("/n" <> path), do: path
  defp display_page_path("/" = path), do: path
  defp display_page_path(path), do: path
end
