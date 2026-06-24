defmodule Unfinal.NamespaceStore do
  @moduledoc """
  Tiny namespace ownership store backed by indexes/namespaces.txt.
  """

  use GenServer

  @type namespace :: String.t()
  @type email :: String.t()
  @type owner :: %{email: email()}
  @index_key "indexes/namespaces.txt"

  @type state :: %{namespace() => owner()}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec valid_namespace?(term()) :: boolean()
  def valid_namespace?(namespace), do: Unfinal.DocumentPath.valid_segment?(namespace)

  @spec claim(namespace(), map()) :: :ok | {:error, :invalid | :taken | :already_claimed}
  def claim(namespace, %{"email" => email}) when is_binary(email) do
    GenServer.call(__MODULE__, {:claim, namespace, email})
  end

  def claim(_namespace, _user), do: {:error, :invalid}

  @spec owner(namespace()) :: owner() | nil
  def owner(namespace), do: GenServer.call(__MODULE__, {:owner, namespace})

  @spec taken?(namespace()) :: boolean()
  def taken?(namespace), do: not is_nil(owner(namespace))

  @spec namespace_for_email(email()) :: namespace() | nil
  def namespace_for_email(email) when is_binary(email),
    do: GenServer.call(__MODULE__, {:namespace_for_email, email})

  def namespace_for_email(_email), do: nil

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_state), do: {:ok, read_all()}

  @impl true
  def handle_call({:claim, namespace, email}, _from, state) do
    cond do
      not valid_namespace?(namespace) ->
        {:reply, {:error, :invalid}, state}

      namespace_for_email(state, email) ->
        {:reply, {:error, :already_claimed}, state}

      Map.has_key?(state, namespace) ->
        {:reply, {:error, :taken}, state}

      true ->
        state = Map.put(state, namespace, %{email: email})
        :ok = write_all(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:owner, namespace}, _from, state) do
    state = reload(state)
    {:reply, Map.get(state, namespace), state}
  end

  def handle_call({:namespace_for_email, email}, _from, state) do
    state = reload(state)
    {:reply, namespace_for_email(state, email), state}
  end

  def handle_call(:clear, _from, _state) do
    :ok = write_all(%{})
    {:reply, :ok, %{}}
  end

  @spec namespace_for_email(state(), email()) :: namespace() | nil
  defp namespace_for_email(state, email) do
    Enum.find_value(state, fn {namespace, owner} ->
      if owner.email == email, do: namespace
    end)
  end

  @spec reload(state()) :: state()
  defp reload(_state), do: read_all()

  @spec read_all() :: state()
  defp read_all do
    case Unfinal.ObjectIndex.get(@index_key) do
      {:ok, content} -> parse(content)
      {:error, _reason} -> %{}
    end
  end

  @spec parse(String.t()) :: state()
  defp parse(content) do
    content
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "\t", parts: 3) do
        [namespace, email] -> Map.put(acc, namespace, %{email: email})
        _parts -> acc
      end
    end)
  end

  @spec write_all(state()) :: :ok
  defp write_all(state) do
    content =
      state
      |> Enum.sort_by(fn {namespace, _owner} -> namespace end)
      |> Enum.map_join("", fn {namespace, owner} ->
        "#{namespace}\t#{owner.email}\n"
      end)

    :ok = Unfinal.ObjectIndex.put(@index_key, content)
  end
end
