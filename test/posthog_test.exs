defmodule PostHogTest do
  use PostHog.Case, async: true

  @moduletag config: [supervisor_name: PostHog]

  import Mox

  setup :setup_supervisor
  setup :verify_on_exit!

  describe "config/0" do
    test "fetches from PostHog by default" do
      assert %{supervisor_name: PostHog} = PostHog.config()
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "uses custom supervisor name" do
      assert %{supervisor_name: CustomPostHog} = PostHog.config(CustomPostHog)
    end
  end

  describe "bare_capture/4" do
    test "simple call" do
      PostHog.bare_capture("case tested", "distinct_id")

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    test "with properties" do
      PostHog.bare_capture("case tested", "distinct_id", %{foo: "bar"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "simple call for custom supervisor" do
      PostHog.bare_capture(CustomPostHog, "case tested", "distinct_id")

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "with properties for custom supervisor" do
      PostHog.bare_capture(CustomPostHog, "case tested", "distinct_id", %{foo: "bar"})

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    test "ignores set context but uses global one from the config" do
      PostHog.set_context(%{hello: "world"})
      PostHog.bare_capture("case tested", "distinct_id", %{foo: "bar"})

      assert [%{properties: properties}] = all_captured()

      assert %{foo: "bar", "$lib": "posthog-elixir", "$lib_version": _} = properties
      refute properties[:hello]
    end
  end

  describe "capture/4" do
    test "simple call" do
      PostHog.capture("case tested", %{distinct_id: "distinct_id"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    test "distinct_id is required" do
      assert {:error, :missing_distinct_id} = PostHog.capture("case tested")
    end

    test "with properties" do
      PostHog.capture("case tested", %{distinct_id: "distinct_id", foo: "bar"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "simple call for custom supervisor" do
      PostHog.capture(CustomPostHog, "case tested", %{distinct_id: "distinct_id"})

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "with properties for custom supervisor" do
      PostHog.capture(CustomPostHog, "case tested", %{distinct_id: "distinct_id", foo: "bar"})

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    test "includes relevant event context" do
      PostHog.set_context(%{hello: "world", distinct_id: "distinct_id"})
      PostHog.set_event_context("case tested", %{foo: "bar"})
      PostHog.set_context(MyPostHog, %{spam: "eggs"})
      PostHog.capture("case tested", %{final: "override"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{
                 hello: "world",
                 foo: "bar",
                 final: "override"
               },
               timestamp: _
             } = event
    end
  end


  describe "set_context/2 + get_context/2" do
    test "default scope" do
      PostHog.set_context(%{foo: "bar"})
      assert PostHog.get_context() == %{foo: "bar"}
      assert PostHog.get_context(PostHog) == %{foo: "bar"}
      assert PostHog.get_event_context("$exception") == %{foo: "bar"}
      assert PostHog.get_event_context(PostHog, "$exception") == %{foo: "bar"}
    end

    test "named scope, all events" do
      PostHog.set_context(MyPostHog, %{foo: "bar"})
      assert PostHog.get_context() == %{}
      assert PostHog.get_event_context("$exception") == %{}
      assert PostHog.get_context(MyPostHog) == %{foo: "bar"}
      assert PostHog.get_event_context(MyPostHog, "$exception") == %{foo: "bar"}
    end
  end

  describe "set_event_context/2 + get_event_context/2" do
    test "default scope" do
      PostHog.set_event_context("$exception", %{foo: "bar"})
      assert PostHog.get_context() == %{}
      assert PostHog.get_event_context("$exception") == %{foo: "bar"}
      assert PostHog.get_context(PostHog) == %{}
      assert PostHog.get_event_context(PostHog, "$exception") == %{foo: "bar"}
    end

    test "named scope" do
      PostHog.set_event_context(MyPostHog, "$exception", %{foo: "bar"})
      assert PostHog.get_context() == %{}
      assert PostHog.get_event_context("$exception") == %{}
      assert PostHog.get_context(MyPostHog) == %{}
      assert PostHog.get_event_context(MyPostHog, "$exception") == %{foo: "bar"}
    end
  end

  describe "flush/2" do
    test "default non-blocking flush" do
      assert :ok = PostHog.flush()
    end

    test "flush with options only (no supervisor name)" do
      assert :ok = PostHog.flush(blocking: false)
      assert {:ok, :flushed} = PostHog.flush([blocking: true])
    end

    test "flush delegates to PostHog.Sender" do
      # This test verifies the delegation works correctly
      # The actual functionality is tested in sender_test.exs
      assert :ok = PostHog.flush(PostHog, blocking: false)
      assert {:ok, :flushed} = PostHog.flush(PostHog, blocking: true, timeout: 1000)
    end
  end
end
