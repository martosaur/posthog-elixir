defmodule PostHog.Sender do
  @moduledoc false
  use GenServer

  defstruct [
    :registry,
    :index,
    :api_client,
    :max_batch_time_ms,
    :max_batch_events,
    events: [],
    num_events: 0
  ]

  def start_link(opts) do
    name =
      opts
      |> Keyword.fetch!(:supervisor_name)
      |> PostHog.Registry.via(__MODULE__, opts[:index])

    callers = Process.get(:"$callers", [])
    Process.flag(:trap_exit, true)

    GenServer.start_link(__MODULE__, {opts, callers}, name: name)
  end

  # Client
  def send(event, supervisor_name) do
    supervisor_name
    |> PostHog.Registry.config()
    |> case do
      %{test_mode: true} ->
        PostHog.Test.remember_event(supervisor_name, event)

      _ ->
        senders =
          supervisor_name
          |> PostHog.Registry.registry_name()
          |> Registry.select([{{{__MODULE__, :_}, :"$1", :"$2"}, [], [{{:"$2", :"$1"}}]}])

        # Pick the first available sender, otherwise random busy one.
        senders
        |> Keyword.get_lazy(:available, fn ->
          senders |> Keyword.values() |> Enum.random()
        end)
        |> GenServer.cast({:event, event})
    end
  end

  @doc """
  Flushes all pending events from all sender processes.

  This function forces all sender processes to immediately send their batched events
  to PostHog, regardless of the current batch size or time limits.

  ## Options

    * `:blocking` - If `true`, waits for all flush operations to complete.
      If `false` (default), returns immediately after triggering flushes.
    * `:timeout` - Maximum time to wait when `:blocking` is `true`.
      Defaults to 5000ms.

  ## Examples

      # Non-blocking flush (default)
      PostHog.Sender.flush()

      # Blocking flush with default timeout
      PostHog.Sender.flush(blocking: true)

      # Blocking flush with custom timeout
      PostHog.Sender.flush(blocking: true, timeout: 10_000)

  ## Returns

  Returns `:ok` when `:blocking` is `false`.
  Returns `{:ok, :flushed}` when `:blocking` is `true` and all flushes complete.
  Returns `{:error, :timeout}` when `:blocking` is `true` and timeout is reached.
  """
  def flush(supervisor_name \\ PostHog, opts \\ []) do
    blocking = Keyword.get(opts, :blocking, false)
    timeout = Keyword.get(opts, :timeout, 5_000)

    supervisor_name
    |> PostHog.Registry.config()
    |> case do
      %{test_mode: true} ->
        # In test mode, no actual flushing needed
        if blocking, do: {:ok, :flushed}, else: :ok

      _ ->
        senders = get_sender_pids(supervisor_name)

        if blocking do
          flush_blocking(senders, timeout)
        else
          flush_non_blocking(senders)
        end
    end
  end

  # Callbacks

  @impl GenServer
  def init({opts, callers}) do
    state = %__MODULE__{
      registry: PostHog.Registry.registry_name(opts[:supervisor_name]),
      index: Keyword.fetch!(opts, :index),
      api_client: Keyword.fetch!(opts, :api_client),
      max_batch_time_ms: Keyword.fetch!(opts, :max_batch_time_ms),
      max_batch_events: Keyword.fetch!(opts, :max_batch_events),
      events: [],
      num_events: 0
    }

    Process.put(:"$callers", callers)

    {:available, nil} =
      Registry.update_value(state.registry, registry_key(state.index), fn _ -> :available end)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:event, event}, state) do
    case state do
      %{num_events: n, events: events} when n + 1 >= state.max_batch_events ->
        {:noreply, %{state | events: [event | events], num_events: n + 1},
         {:continue, :send_batch}}

      %{num_events: 0, events: events} ->
        Process.send_after(self(), :batch_time_reached, state.max_batch_time_ms)

        {:noreply, %{state | events: [event | events], num_events: 1}}

      %{num_events: n, events: events} ->
        {:noreply, %{state | events: [event | events], num_events: n + 1}}
    end
  end

  @impl GenServer
  def handle_call(:flush_sync, _from, %{num_events: 0} = state) do
    # No events to flush
    {:reply, :ok, state}
  end

  def handle_call(:flush_sync, _from, state) do
    # Flush events synchronously and reply when done
    {result, new_state} = do_flush_events(state)

    # Reply with the API result
    case result do
      {:ok, _response} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, new_state}
    end
  end

  @impl GenServer
  def handle_info(:batch_time_reached, state) do
    {:noreply, state, {:continue, :send_batch}}
  end

  @impl GenServer
  def handle_continue(:send_batch, state) do
    {_result, new_state} = do_flush_events(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def terminate(_reason, %{num_events: n} = state) when n > 0 do
    {_result, _new_state} = do_flush_events(state)
  end

  def terminate(_reason, _state), do: :ok

  # Helper functions for flush functionality

  # Performs the actual event flushing with registry status management.
  #
  # This function:
  # 1. Marks the sender as busy in the registry
  # 2. Makes the HTTP request to PostHog API
  # 3. Marks the sender as available again
  # 4. Returns the result and updated state
  #
  # Returns: {api_result, new_state}
  defp do_flush_events(state) do
    # Before we initiate an HTTP request that might block the process
    # for a potentially noticeable time, we signal to the outside world that this
    # sender is currently busy and if there is another sender available it
    # should be used instead.
    Registry.update_value(state.registry, registry_key(state.index), fn _ -> :busy end)

    # Make the actual API call
    api_result = PostHog.API.batch(state.api_client, state.events)

    # Mark as available again
    Registry.update_value(state.registry, registry_key(state.index), fn _ -> :available end)

    # Return result and updated state (with cleared events)
    new_state = %{state | events: [], num_events: 0}
    {api_result, new_state}
  end

  defp get_sender_pids(supervisor_name) do
    supervisor_name
    |> PostHog.Registry.registry_name()
    |> Registry.select([{{{__MODULE__, :_}, :"$1", :"$2"}, [], [:"$1"]}])
  end

  defp flush_non_blocking(sender_pids) do
    Enum.each(sender_pids, fn sender_pid ->
      Kernel.send(sender_pid, :batch_time_reached)
    end)

    :ok
  end

  defp flush_blocking(sender_pids, timeout) do
    # Use Task.async_stream to make parallel GenServer calls with proper timeout
    results =
      sender_pids
      |> Task.async_stream(
        fn sender_pid ->
          GenServer.call(sender_pid, :flush_sync, timeout)
        end,
        max_concurrency: length(sender_pids),
        timeout: timeout + 1_000, # Give a bit extra time for the stream itself
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    # Check if all flushes completed successfully
    case results do
      results when length(results) == length(sender_pids) ->
        # Check if any failed
        failed_results = Enum.filter(results, fn
          {:ok, :ok} -> false
          {:ok, {:error, _}} -> true
          {:exit, _} -> true
          _ -> true
        end)

        case failed_results do
          [] -> {:ok, :flushed}
          _ -> {:error, {:some_flushes_failed, failed_results}}
        end

      _ ->
        {:error, :timeout}
    end
  end

  defp registry_key(index), do: {__MODULE__, index}
end
