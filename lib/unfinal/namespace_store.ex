defmodule Unfinal.NamespaceStore do
  @moduledoc """
  Tiny namespace ownership store backed by namespaces.txt.
  """

  use GenServer

  @type namespace :: String.t()
  @type user_id :: String.t()
  @type email :: String.t()
  @type owner :: %{user_id: user_id(), email: email()}
  @type state :: %{namespace() => owner()}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec valid_namespace?(term()) :: boolean()
  def valid_namespace?(namespace) when is_binary(namespace),
    do: Regex.match?(~r/^[a-z0-9]+$/, namespace)

  def valid_namespace?(_namespace), do: false

  @spec claim(namespace(), map()) :: :ok | {:error, :invalid | :taken | :already_claimed}
  def claim(namespace, %{"id" => user_id, "email" => email})
      when is_binary(user_id) and is_binary(email) do
    GenServer.call(__MODULE__, {:claim, namespace, user_id, email})
  end

  def claim(_namespace, _user), do: {:error, :invalid}

  @spec owner(namespace()) :: owner() | nil
  def owner(namespace), do: GenServer.call(__MODULE__, {:owner, namespace})

  @spec taken?(namespace()) :: boolean()
  def taken?(namespace), do: not is_nil(owner(namespace))

  @spec namespace_for_user(user_id()) :: namespace() | nil
  def namespace_for_user(user_id) when is_binary(user_id),
    do: GenServer.call(__MODULE__, {:namespace_for_user, user_id})

  def namespace_for_user(_user_id), do: nil

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_state), do: {:ok, read_all()}

  @impl true
  def handle_call({:claim, namespace, user_id, email}, _from, state) do
    cond do
      not valid_namespace?(namespace) ->
        {:reply, {:error, :invalid}, state}

      namespace_for_user(state, user_id) ->
        {:reply, {:error, :already_claimed}, state}

      Map.has_key?(state, namespace) ->
        {:reply, {:error, :taken}, state}

      true ->
        state = Map.put(state, namespace, %{user_id: user_id, email: email})
        :ok = write_all(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:owner, namespace}, _from, state) do
    state = reload(state)
    {:reply, Map.get(state, namespace), state}
  end

  def handle_call({:namespace_for_user, user_id}, _from, state) do
    state = reload(state)
    {:reply, namespace_for_user(state, user_id), state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  @spec namespace_for_user(state(), user_id()) :: namespace() | nil
  defp namespace_for_user(state, user_id) do
    Enum.find_value(state, fn {namespace, owner} ->
      if owner.user_id == user_id, do: namespace
    end)
  end

  @spec reload(state()) :: state()
  defp reload(_state), do: read_all()

  @spec read_all() :: state()
  defp read_all do
    case File.read(file_path()) do
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
        [namespace, user_id, email] -> Map.put(acc, namespace, %{user_id: user_id, email: email})
        _parts -> acc
      end
    end)
  end

  @spec write_all(state()) :: :ok
  defp write_all(state) do
    path = file_path()
    :ok = File.mkdir_p(Path.dirname(path))

    content =
      state
      |> Enum.sort_by(fn {namespace, _owner} -> namespace end)
      |> Enum.map_join("", fn {namespace, owner} ->
        "#{namespace}\t#{owner.user_id}\t#{owner.email}\n"
      end)

    File.write!(path, content)
  end

  @spec file_path() :: String.t()
  defp file_path, do: Path.join(System.get_env("UNFINAL_DATA_DIR", "./.data"), "namespaces.txt")
end
