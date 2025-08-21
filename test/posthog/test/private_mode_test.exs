defmodule PostHog.Test.PrivateModeTest do
  use PostHog.Case, async: true

  alias PostHog.Test

  @supervisor_name __MODULE__
  @moduletag config: [supervisor_name: @supervisor_name]

  setup_all :setup_supervisor

  test "same process", %{test: test} do
    PostHog.bare_capture(@supervisor_name, test, "user123")

    assert [%{event: ^test}] = Test.all_captured(@supervisor_name)
  end

  test "caller tracking", %{test: test} do
    task =
      Task.async(fn ->
        PostHog.bare_capture(@supervisor_name, test, "user123")
      end)

    assert :ok = Task.await(task)
    assert [%{event: ^test}] = Test.all_captured(@supervisor_name)
  end

  test "no ownership link", %{test: test} do
    test_pid = self()

    spawn(fn ->
      PostHog.bare_capture(@supervisor_name, test, "user123")
      send(test_pid, :ready)
    end)

    assert_receive :ready
    assert [] = Test.all_captured(@supervisor_name)
  end

  test "explicit allowance", %{test: test} do
    test_pid = self()

    pid =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        PostHog.bare_capture(@supervisor_name, test, "user123")
        send(test_pid, :ready)
      end)

    Test.allow(@supervisor_name, test_pid, pid)

    send(pid, :go)
    assert_receive :ready

    assert [%{event: ^test}] = Test.all_captured(@supervisor_name)
  end
end
