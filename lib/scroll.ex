defmodule Library.Scroll do
  use GenServer

  @impl GenServer
  def init(state) do
    Process.send_after(self(), :auto_save, 30_000)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:read, key}, _, %{} = state) do
    {:reply, Map.fetch(state, key), state}
  end

  def handle_call({:read, _key}, _, state) do
    {:reply, {:error, :state_is_not_a_map}, state}
  end

  def handle_call(:read, _, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:write, key, value}, _, %{} = state) do
    state = Map.put(state, key, value)
            |> Map.put(:__dirty__, true)

    {:reply, {:ok, value}, state}
  end

  def handle_call({:write, _key, _value}, _, state) do
    {:reply, {:error, :state_is_not_a_map}, state}
  end

  def handle_call({:write, %{id: _id} = new_state}, _, _) do
    new_state = Map.put(new_state, :__dirty__, true)

    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call({:write, %{} = new_state}, _, %{id: id}) do
    new_state = Map.put(new_state, :id, id)
                |> Map.put(:__dirty__, true)

    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call({:write, _}, _, state) do
    {:reply, {:error, :no_id}, state}
  end

  def handle_call({:mutate, key, transformer}, _, %{} = state) do
    value = case Map.fetch(state, key) do
              {:ok, value} ->
                value
              :error ->
                nil
            end

    case transformer.(value) do
      {:ok, ^value} ->
        {:reply, {:ok, value}, state}
      {:ok, value} ->
        state = Map.put(state, key, value)
                |> Map.put(:__dirty__, true)

        {:reply, {:ok, value}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
      :error ->
        {:reply, :error, state}
      ^value ->
        {:reply, {:ok, value}, state}
      value ->
        state = Map.put(state, key, value)
                |> Map.put(:__dirty__, true)

        {:reply, {:ok, value}, state}
    end
  end

  def handle_call({:mutate, _, _}, _, state) do
    {:reply, {:error, :state_is_not_a_map}, state}
  end

  def handle_call({:mutate, transformer}, _, %{id: id} = state) do
    case transformer.(state) do
      {:ok, ^state} ->
        {:reply, {:ok, state}, state}

      {:ok, %{id: _id} = state} ->
        state = Map.put(state, :__dirty__, true)

        {:reply, {:ok, state}, state}

      {:ok, %{} = state} ->
        state = Map.put(state, :id, id)
                |> Map.put(:__dirty__, true)

        {:reply, {:ok, state}, state}

      {:ok, _} ->
        {:reply, {:error, :state_is_not_a_map}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :error ->
        {:reply, :error, state}

      %{id: _id} = state ->
        state = Map.put(state, :__dirty__, true)

        {:reply, {:ok, state}, state}

      %{} = state ->
        state = Map.put(state, :id, id)
                |> Map.put(:__dirty__, true)

        {:reply, {:ok, state}, state}

      _ ->
        {:reply, {:error, :state_is_not_a_map}, state}

    end
  end

  def handle_call({:mutate, _}, _, state) do
    {:reply, {:error, :no_id}, state}
  end

  def handle_call({:delete, key}, _, state) do
    case Map.fetch(state, key) do
      {:ok, value} ->
        state = Map.delete(state, key)
                |> Map.put(:__dirty__, true)

        {:reply, {:ok, value}, state}

      :error ->
        {:reply, :ok, state}

    end
  end

  def handle_call(:delete, _, %{id: id} = state) do
    dets_table_name(id)
    |> File.rm

    {:stop, :normal, {:ok, state}, %{}}
  end

  def handle_call(:delete, _, state) do
    {:reply, {:error, :no_id}, state}
  end

  def handle_call(:persist, _, %{id: id} = state) do
    case persist(id, state) do
      {:ok, state} ->
        {:reply, {:ok, state}, state}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:persist, _, state) do
    {:reply, {:error, :no_id}, state}
  end

  @impl GenServer
  def handle_info(:auto_save, %{id: id, __dirty__: true} = state) do
    result = persist(id, state)
    Process.send_after(self(), :auto_save, 30_000)

    case result do
      {:ok, state} ->
        {:noreply, state}
      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:auto_save, state) do
    Process.send_after(self(), :auto_save, 30_000)

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{id: id} = state) do
    persist(id, state)
  end

  def terminate(_reason, _state) do
    :ok
  end

  def start_link({name, state}) do
    GenServer.start_link(__MODULE__, state, name: name)
  end

  def name(id) do
    {:via, Registry, {Library.Registry, id}}
  end

  def alive?(id) do
    GenServer.whereis(name(id)) != nil
  end

  def get_pid(id) do
    GenServer.whereis(name(id))
  end

  def dets_table_name(id) do
    "#{id}.dets"
    |> String.to_charlist
  end

  def new(id) do
    state = restore(id)
    DynamicSupervisor.start_child(Library.Librarian, {__MODULE__, {name(id), state}})
  end

  defp restore(id) do
    table_name = dets_table_name(id)
    with {:ok, table} <- :dets.open_file(table_name, [type: :set]) do
      state = :dets.select(table, [{:"$1", [], [:"$1"]}])
              |> Enum.into(%{id: id})

      :dets.close(table)
      state
    else
      _ -> %{id: id}
    end
  end

  def persist(id, state) do
    table_name = dets_table_name(id)
    with {:ok, table} <- :dets.open_file(table_name, [type: :set]) do
      state = Map.put(state, :__dirty__, false)
      Enum.each(state, fn record -> :dets.insert(table, record) end)
      :dets.close(table)

      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :failed_to_write_table}
    end
  end

end
