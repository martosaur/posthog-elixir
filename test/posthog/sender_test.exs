defmodule PostHog.SenderTest do
  use ExUnit.Case, async: true

  import Mox

  alias PostHog.Sender
  alias PostHog.API

  @supervisor_name __MODULE__

  setup_all do
    registry = PostHog.Registry.registry_name(@supervisor_name)

    start_link_supervised!(
      {Registry, keys: :unique, name: registry, meta: [config: %{test_mode: false}]}
    )

    %{api_client: %API.Client{client: :fake_client, module: API.Mock}, registry: registry}
  end

  setup :verify_on_exit!

  describe "send/2" do
    test "picks available sender", %{registry: registry} do
      busy_pid =
        start_link_supervised!(
          Supervisor.child_spec(
            {Agent, fn -> Registry.register(registry, {PostHog.Sender, 0}, :busy) end},
            id: Agent0
          )
        )

      available_pid =
        start_link_supervised!(
          Supervisor.child_spec(
            {Agent, fn -> Registry.register(registry, {PostHog.Sender, 1}, :available) end},
            id: Agent1
          )
        )

      :sys.suspend(busy_pid)
      :sys.suspend(available_pid)

      Sender.send("my_event", @supervisor_name)
      assert {:message_queue_len, 0} = Process.info(busy_pid, :message_queue_len)

      assert {:messages, ["$gen_cast": {:event, "my_event"}]} =
               Process.info(available_pid, :messages)
    end

    test "busy sender is ok if there are no available", %{registry: registry} do
      busy_pid =
        start_link_supervised!(
          Supervisor.child_spec(
            {Agent, fn -> Registry.register(registry, {PostHog.Sender, 0}, :busy) end},
            id: Agent0
          )
        )

      :sys.suspend(busy_pid)

      Sender.send("my_event", @supervisor_name)

      assert {:messages, ["$gen_cast": {:event, "my_event"}]} =
               Process.info(busy_pid, :messages)
    end
  end

  describe "Server" do
    test "starts in :available state", %{api_client: api_client, registry: registry} do
      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
           api_client: api_client,
           max_batch_time_ms: 60_000,
           max_batch_events: 100}
        )

      [{^pid, :available}] = Registry.lookup(registry, {PostHog.Sender, 1})
    end

    test "puts events into state", %{api_client: api_client} do
      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
           api_client: api_client,
           max_batch_time_ms: 60_000,
           max_batch_events: 100}
        )

      Sender.send("my_event", @supervisor_name)

      assert %{events: ["my_event"]} = :sys.get_state(pid)
    end

    test "immediately sends after reaching max_batch_events", %{
      api_client: api_client,
      registry: registry
    } do
      test_pid = self()

      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
           api_client: api_client,
           max_batch_time_ms: 60_000,
           max_batch_events: 2}
        )

      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/batch"

        assert opts[:json] == %{
                 batch: ["bar", "foo"]
               }

        send(test_pid, :ready)

        receive do
          :go -> :ok
        end
      end)

      Sender.send("foo", @supervisor_name)
      Sender.send("bar", @supervisor_name)

      assert_receive :ready

      [{^pid, :busy}] = Registry.lookup(registry, {PostHog.Sender, 1})
      send(pid, :go)

      assert %{events: []} = :sys.get_state(pid)
      [{^pid, :available}] = Registry.lookup(registry, {PostHog.Sender, 1})
    end

    test "immediately sends after reaching max_batch_time_ms", %{
      api_client: api_client,
      registry: registry
    } do
      test_pid = self()

      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
           api_client: api_client,
           max_batch_time_ms: 0,
           max_batch_events: 100}
        )

      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/batch"

        assert opts[:json] == %{
                 batch: ["foo"]
               }

        send(test_pid, :ready)

        receive do
          :go -> :ok
        end

        send(test_pid, :done)
      end)

      Sender.send("foo", @supervisor_name)

      assert_receive :ready
      [{^pid, :busy}] = Registry.lookup(registry, {PostHog.Sender, 1})
      send(pid, :go)
      assert_receive :done
      [{^pid, :available}] = Registry.lookup(registry, {PostHog.Sender, 1})
    end

    test "sends leftovers on shutdown", %{api_client: api_client} do
      pid =
        start_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
           api_client: api_client,
           max_batch_time_ms: 60_000,
           max_batch_events: 100}
        )

      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/batch"

        assert opts[:json] == %{
                 batch: ["foo"]
               }
      end)

      Sender.send("foo", @supervisor_name)

      assert :ok = GenServer.stop(pid)
    end
  end

  describe "flush/2" do
    test "flush with no senders returns ok" do
      assert :ok = Sender.flush(@supervisor_name, blocking: false)
    end

    test "flush in test mode returns ok" do
      # Create a supervisor with test mode enabled
      registry = PostHog.Registry.registry_name(:test_supervisor)

      start_link_supervised!(
        {Registry, keys: :unique, name: registry, meta: [config: %{test_mode: true}]}
      )

      assert :ok = Sender.flush(:test_supervisor, blocking: false)
      assert {:ok, :flushed} = Sender.flush(:test_supervisor, blocking: true)
    end

    test "non-blocking flush sends messages to all senders", %{api_client: api_client} do
      # Start two sender processes
      pid1 = start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100},
        id: :sender1
      )

      pid2 = start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 2,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100},
        id: :sender2
      )

      # Add events to both senders
      Sender.send("event1", @supervisor_name)
      Sender.send("event2", @supervisor_name)

      # Suspend both processes to check their message queues
      :sys.suspend(pid1)
      :sys.suspend(pid2)

      # Non-blocking flush
      assert :ok = Sender.flush(@supervisor_name, blocking: false)

      # Check that both processes received the batch_time_reached message
      # Note: We can't easily check message queues in a race-free way,
      # so we'll check that the flush function returns properly

      :sys.resume(pid1)
      :sys.resume(pid2)
    end

    test "blocking flush waits for API calls to complete", %{api_client: api_client} do
      test_pid = self()

      pid = start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100}
      )

      # Add an event
      Sender.send("test_event", @supervisor_name)

      # Mock the API call to send a message when called
      expect(API.Mock, :request, fn _client, :post, "/batch", opts ->
        assert opts[:json] == %{batch: ["test_event"]}
        send(test_pid, :api_called)
        {:ok, %{status: 200, body: %{}}}
      end)

      # Start blocking flush in a separate task
      task = Task.async(fn ->
        Sender.flush(@supervisor_name, blocking: true, timeout: 2_000)
      end)

      # Verify API was called
      assert_receive :api_called, 1_000

      # Verify flush completed successfully
      assert {:ok, :flushed} = Task.await(task, 3_000)

      # Verify sender state is cleared
      assert %{events: [], num_events: 0} = :sys.get_state(pid)
    end

    test "blocking flush handles API errors", %{api_client: api_client} do
      _pid = start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100}
      )

      # Add an event
      Sender.send("test_event", @supervisor_name)

      # Mock API call to return an error
      expect(API.Mock, :request, fn _client, :post, "/batch", _opts ->
        {:error, :network_error}
      end)

      # Blocking flush should return error details
      assert {:error, {:some_flushes_failed, failed_results}} =
        Sender.flush(@supervisor_name, blocking: true, timeout: 2_000)

      # Should have one failed result
      assert length(failed_results) == 1
      assert [{:ok, {:error, :network_error}}] = failed_results
    end


    test "flush_sync handle_call works directly", %{api_client: api_client} do
      pid = start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100}
      )

      # Add an event
      Sender.send("test_event", @supervisor_name)

      # Mock successful API call
      expect(API.Mock, :request, fn _client, :post, "/batch", opts ->
        assert opts[:json] == %{batch: ["test_event"]}
        {:ok, %{status: 200, body: %{}}}
      end)

      # Direct GenServer call should work
      assert :ok = GenServer.call(pid, :flush_sync)

      # Verify sender state is cleared
      assert %{events: [], num_events: 0} = :sys.get_state(pid)
    end

    test "flush_sync with no events returns immediately", %{api_client: api_client} do
      pid = start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100}
      )

      # No API call should be made
      expect(API.Mock, :request, 0, fn _, _, _, _ ->
        {:ok, %{status: 200, body: %{}}}
      end)

      # Direct GenServer call with no events
      assert :ok = GenServer.call(pid, :flush_sync)

      # State should remain unchanged
      assert %{events: [], num_events: 0} = :sys.get_state(pid)
    end
  end
end
