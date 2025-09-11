defmodule PostHog.FeatureFlags.PollerTest do
  use ExUnit.Case, async: false
  import Mox

  alias PostHog.FeatureFlags.Poller
  alias PostHog.Config

  # Define a mock for the API client
  defmock(PostHog.MockAPIClient, for: PostHog.API.Client)

  setup :verify_on_exit!

  describe "local_evaluation_enabled?/1" do
    test "returns true when enable_local_evaluation is true and personal_api_key is set" do
      config = %{enable_local_evaluation: true, personal_api_key: "test_key"}

      assert Poller.local_evaluation_enabled?(config) == true
    end

    test "returns false when enable_local_evaluation is false" do
      config = %{enable_local_evaluation: false, personal_api_key: "test_key"}

      assert Poller.local_evaluation_enabled?(config) == false
    end

    test "returns false when personal_api_key is nil" do
      config = %{enable_local_evaluation: true, personal_api_key: nil}

      assert Poller.local_evaluation_enabled?(config) == false
    end

    test "returns false when personal_api_key is not set" do
      config = %{enable_local_evaluation: true}

      assert Poller.local_evaluation_enabled?(config) == false
    end
  end

  describe "start_link/1" do
    test "starts successfully with valid config" do
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "test_key",
        supervisor_name: :test_poller,
        feature_flags_poll_interval: 1000,
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "test_api_key"
      }

      # Mock the API call that happens during initialization
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :get, "/api/feature_flag/local_evaluation/", _opts ->
          {:ok, %{
            status: 200,
            body: %{
              "flags" => [],
              "group_type_mapping" => %{},
              "cohorts" => %{}
            }
          }}
      end)

      assert {:ok, pid} = Poller.start_link(config)
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end

    test "starts but doesn't poll when local evaluation is disabled" do
      config = %{
        enable_local_evaluation: false,
        personal_api_key: nil,
        supervisor_name: :test_poller_disabled,
        feature_flags_poll_interval: 1000,
        feature_flags_request_timeout: 5000
      }

      assert {:ok, pid} = Poller.start_link(config)
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "get_feature_flags/1" do
    setup do
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "test_key",
        supervisor_name: :test_poller_get,
        feature_flags_poll_interval: 30_000,
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "test_api_key"
      }

      # Mock successful API response
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :get, "/api/feature_flag/local_evaluation/", _opts ->
          {:ok, %{
            status: 200,
            body: %{
              "flags" => [
                %{
                  "key" => "test-flag",
                  "active" => true,
                  "filters" => %{
                    "groups" => [
                      %{"properties" => [], "rollout_percentage" => 100}
                    ]
                  }
                }
              ],
              "group_type_mapping" => %{"0" => "company"},
              "cohorts" => %{}
            }
          }}
      end)

      {:ok, pid} = Poller.start_link(config)

      # Give it a moment to poll
      Process.sleep(100)

      %{config: config, pid: pid}
    end

    test "returns feature flags data", %{config: config, pid: pid} do
      result = Poller.get_feature_flags(config)

      assert %{
        feature_flags: flags,
        group_type_mapping: group_mapping,
        cohorts: cohorts,
        last_updated: last_updated
      } = result

      assert is_list(flags)
      assert is_map(group_mapping)
      assert is_map(cohorts)
      assert %DateTime{} = last_updated

      # Clean up
      GenServer.stop(pid)
    end

    test "includes expected flag data", %{config: config, pid: pid} do
      result = Poller.get_feature_flags(config)

      assert [flag] = result.feature_flags
      assert flag["key"] == "test-flag"
      assert flag["active"] == true

      assert result.group_type_mapping == %{"0" => "company"}

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "refresh_feature_flags/1" do
    test "triggers a refresh of feature flags" do
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "test_key",
        supervisor_name: :test_poller_refresh,
        feature_flags_poll_interval: 30_000,
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "test_api_key"
      }

      # Mock API calls - one for initial load, one for refresh
      expect(PostHog.MockAPIClient, :request, 2, fn
        :mock, :get, "/api/feature_flag/local_evaluation/", _opts ->
          {:ok, %{
            status: 200,
            body: %{
              "flags" => [],
              "group_type_mapping" => %{},
              "cohorts" => %{}
            }
          }}
      end)

      {:ok, pid} = Poller.start_link(config)

      # Trigger refresh
      assert :ok = Poller.refresh_feature_flags(config)

      # Give it a moment to process
      Process.sleep(50)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "error handling" do
    test "handles API errors gracefully" do
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "invalid_key",
        supervisor_name: :test_poller_error,
        feature_flags_poll_interval: 1000,
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "test_api_key"
      }

      # Mock API error
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :get, "/api/feature_flag/local_evaluation/", _opts ->
          {:ok, %{status: 401, body: %{"error" => "Unauthorized"}}}
      end)

      {:ok, pid} = Poller.start_link(config)

      # Give it a moment to process the error
      Process.sleep(100)

      # Should still be running despite the error
      assert Process.alive?(pid)

      # Should return empty data when there's an error
      result = Poller.get_feature_flags(config)
      assert result.feature_flags == []
      assert result.last_updated == nil

      # Clean up
      GenServer.stop(pid)
    end

    test "handles network errors gracefully" do
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "test_key",
        supervisor_name: :test_poller_network_error,
        feature_flags_poll_interval: 1000,
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "test_api_key"
      }

      # Mock network error
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :get, "/api/feature_flag/local_evaluation/", _opts ->
          {:error, :timeout}
      end)

      {:ok, pid} = Poller.start_link(config)

      # Give it a moment to process the error
      Process.sleep(100)

      # Should still be running despite the error
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end

    test "handles quota limited response" do
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "test_key",
        supervisor_name: :test_poller_quota,
        feature_flags_poll_interval: 1000,
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "test_api_key"
      }

      # Mock quota limited response
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :get, "/api/feature_flag/local_evaluation/", _opts ->
          {:ok, %{status: 402, body: %{"error" => "Quota exceeded"}}}
      end)

      {:ok, pid} = Poller.start_link(config)

      # Give it a moment to process
      Process.sleep(100)

      # Should still be running
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "polling lifecycle" do
    test "schedules periodic polling" do
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "test_key",
        supervisor_name: :test_poller_periodic,
        feature_flags_poll_interval: 100,  # Very short interval for testing
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "test_api_key"
      }

      # Mock multiple API calls (initial + periodic)
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :get, "/api/feature_flag/local_evaluation/", _opts ->
          {:ok, %{
            status: 200,
            body: %{
              "flags" => [],
              "group_type_mapping" => %{},
              "cohorts" => %{}
            }
          }}
      end)
      |> times(2)  # Expect at least 2 calls

      {:ok, pid} = Poller.start_link(config)

      # Wait for a couple of polling cycles
      Process.sleep(250)

      # Should still be running
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end
  end
end
