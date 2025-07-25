defmodule PostHog.Test.SharedModeTest do
  use PostHog.Case, async: false

  alias PostHog.Test

  @supervisor_name __MODULE__
  @moduletag config: [supervisor_name: @supervisor_name]

  setup_all :setup_supervisor
  setup_all {Test, :set_posthog_shared}

  test "same process", %{test: test} do
    PostHog.bare_capture(@supervisor_name, test, "user123")

    assert events = Test.all_captured(@supervisor_name)
    assert Enum.any?(events, &match?(%{event: ^test}, &1))
  end

  test "no ownership link", %{test: test} do
    test_pid = self()

    spawn(fn ->
      PostHog.bare_capture(@supervisor_name, test, "user123")
      send(test_pid, :ready)
    end)

    assert_receive :ready
    assert events = Test.all_captured(@supervisor_name)
    assert Enum.any?(events, &match?(%{event: ^test}, &1))
  end
end
