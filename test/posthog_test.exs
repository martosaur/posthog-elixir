defmodule PostHogTest do
  use PostHog.Case, async: true

  @moduletag config: [supervisor_name: PostHog]

  import Mox

  alias PostHog.API

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

  describe "flags/2" do
    test "returns body on success" do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/flags"
        assert opts[:params] == %{v: 2}

        assert opts[:json] == %{
                 distinct_id: "foo"
               }

        {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end)

      assert {:ok, %{status: 200, body: %{}}} = PostHog.flags(%{distinct_id: "foo"})
    end

    test "sophisticated body" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{
                 distinct_id: "foo",
                 groups: %{group_type: "group_id"}
               }

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} =
               PostHog.flags(%{distinct_id: "foo", groups: %{group_type: "group_id"}})
    end

    test "client errors passed as is" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:error, :transport_error}
      end)

      assert {:error, :transport_error} = PostHog.flags("foo")
    end

    test "non-200 is wrapped in error" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 503}}
      end)

      assert {:error,
              %PostHog.UnexpectedResponseError{
                response: %{status: 503},
                message: "Unexpected response"
              }} =
               PostHog.flags(%{distinct_id: "foo"})
    end

    test "unexpected response body" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: "internal server error"}}
      end)

      assert {:error,
              %PostHog.UnexpectedResponseError{
                response: "internal server error",
                message: "Expected response body to have \"flags\" key"
              }} = PostHog.flags(%{distinct_id: "foo"})
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{body: %{"flags" => _}}} = PostHog.flags(MyPostHog, %{distinct_id: "foo"})
    end
  end

  describe "get_all_feature_flags/2" do
    test "returns flags on success" do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/flags"
        assert opts[:params] == %{v: 2}

        assert opts[:json] == %{
                 distinct_id: "foo"
               }

        {:ok, %{status: 200, body: %{"flags" => %{"foo" => %{}}}}}
      end)

      assert {:ok, %{"foo" => %{}}} = PostHog.get_all_feature_flags("foo")
    end

    test "full request map" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo", personal_properties: %{foo: "bar"}}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} =
               PostHog.get_all_feature_flags(%{
                 distinct_id: "foo",
                 personal_properties: %{foo: "bar"}
               })
    end

    test "distinct_id is taken from the context if not passed" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} = PostHog.get_all_feature_flags()
    end

    test "explicit distinct_id preferred over context" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "bar"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} = PostHog.get_all_feature_flags("bar")
    end

    test "missing distinct_Id" do
      assert {:error,
              %PostHog.Error{
                message:
                  "distinct_id is required but wasn't explicitely provided or found in the context"
              }} =
               PostHog.get_all_feature_flags(nil)
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{"example-feature-flag-1" => %{}}} =
               PostHog.get_all_feature_flags(MyPostHog, "foo")
    end
  end

  describe "check_feature_flag/3" do
    test "returns variant if present" do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/flags"
        assert opts[:params] == %{v: 2}

        assert opts[:json] == %{
                 distinct_id: "foo"
               }

        {:ok,
         %{
           status: 200,
           body: %{"flags" => %{"myflag" => %{"enabled" => true, "variant" => "variant1"}}}
         }}
      end)

      assert {:ok, "variant1"} = PostHog.check_feature_flag("myflag", "foo")
    end

    test "returns true if enabled" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"enabled" => true}}}}}
      end)

      assert {:ok, true} = PostHog.check_feature_flag("myflag", "foo")
    end

    test "returns false otherwise" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{}}}}}
      end)

      assert {:ok, false} = PostHog.check_feature_flag("myflag", "foo")
    end

    test "full request map" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo", personal_properties: %{foo: "bar"}}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} =
               PostHog.check_feature_flag("example-feature-flag-1", %{
                 distinct_id: "foo",
                 personal_properties: %{foo: "bar"}
               })
    end

    test "distinct_id is taken from the context if not passed" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} = PostHog.check_feature_flag("example-feature-flag-1")
    end

    test "explicit distinct_id preferred over context" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "bar"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} = PostHog.check_feature_flag("example-feature-flag-1", "bar")
    end

    test "missing distinct_Id" do
      assert {:error,
              %PostHog.Error{
                message:
                  "distinct_id is required but wasn't explicitely provided or found in the context"
              }} =
               PostHog.check_feature_flag("example-feature-flag-1")
    end

    test "sets feature flag context" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"variant" => "variant1"}}}}}
      end)

      assert {:ok, "variant1"} = PostHog.check_feature_flag("myflag", "foo")
      assert %{"$feature/myflag" => "variant1"} = PostHog.get_context()
    end

    test "publishes $feature_flag_called event " do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"variant" => "variant1"}}}}}
      end)

      assert {:ok, "variant1"} = PostHog.check_feature_flag("myflag", "foo")

      assert [
               %{
                 event: "$feature_flag_called",
                 distinct_id: "foo",
                 properties: %{"$feature_flag": "myflag", "$feature_flag_response": "variant1"}
               }
             ] = all_captured()
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} = PostHog.check_feature_flag(MyPostHog, "example-feature-flag-1", "foo")
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
end
