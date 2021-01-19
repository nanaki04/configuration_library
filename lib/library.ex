defmodule Library do
  use GenServer
  alias Library.Scroll

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  @impl GenServer
  def handle_call(message, _, state) when is_tuple(message) do
    case Tuple.to_list(message) do
      [command, scroll_id] ->
        reply = call_to_scroll(scroll_id, command)
        {:reply, reply, state}

      [_ | [scroll_id | _]] ->
        reply = call_to_scroll(scroll_id, Tuple.delete_at(message, 1))
        {:reply, reply, state}
      _ ->
        {:reply, {:error, :unexpected_message_format}, state}
    end
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: {:global, __MODULE__})
  end

  defp get_or_create(scroll_id) do
    case GenServer.whereis(Scroll.name(scroll_id)) do
      nil -> Scroll.new(scroll_id)
      pid -> {:ok, pid}
    end
    |> case do
      {:ok, pid} ->
        {:ok, pid}
      {:error, reason} ->
        {:error, reason}
      reason ->
        {:error, reason}
    end
  end

  defp call_to_scroll(scroll_id, message) do
    with {:ok, pid} <- get_or_create(scroll_id) do
      GenServer.call(pid, message)
    end
  end

end
