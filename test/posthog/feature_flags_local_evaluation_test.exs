defmodule PostHog.FeatureFlagsLocalEvaluationTest do
  use ExUnit.Case, async: false
  import Mox

  alias PostHog.FeatureFlags

  # Define a mock for the API client
  defmock(PostHog.MockAPIClient, for: PostHog.API.Client)

  setup :verify_on_exit!

  describe "local evaluation integration" do
    setup do
      # Start a test PostHog instance with local evaluation enabled
      config = %{
        enable_local_evaluation: true,
        personal_api_key: "phx_test_key",
        supervisor_name: :test_posthog_local,
        feature_flags_poll_interval: 60_000,  # Long interval to avoid interference
        feature_flags_request_timeout: 5000,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "phc_test_key",
        public_url: "https://us.i.posthog.com"
      }

      # Mock the PostHog.config/1 function
      expect(PostHog, :config, fn :test_posthog_local -> config end)
      |> allow(self(), :test_posthog_local)
      |> times(:any)

      %{config: config}
    end

    test "check/3 uses local evaluation when available", %{config: config} do
      flag_definitions = [
        %{
          "key" => "local-test-flag",
          "active" => true,
          "filters" => %{
            "groups" => [
              %{
                "properties" => [
                  %{
                    "key" => "country",
                    "operator" => "exact",
                    "value" => "US",
                    "type" => "person"
                  }
                ],
                "rollout_percentage" => 100
              }
            ]
          }
        }
      ]

      # Mock the poller functions
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: flag_definitions,
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: ~U[2023-01-01 00:00:00Z]
        }
      end)

      # Test with matching properties - should use local evaluation
      result = FeatureFlags.check(:test_posthog_local, "local-test-flag", %{
        distinct_id: "user123",
        person_properties: %{"country" => "US"}
      })

      assert {:ok, true} = result

      # Test with non-matching properties - should use local evaluation
      result = FeatureFlags.check(:test_posthog_local, "local-test-flag", %{
        distinct_id: "user123",
        person_properties: %{"country" => "CA"}
      })

      assert {:ok, false} = result
    end

    test "check/3 with only_evaluate_locally option", %{config: config} do
      flag_definitions = [
        %{
          "key" => "local-only-flag",
          "active" => true,
          "filters" => %{
            "groups" => [
              %{"properties" => [], "rollout_percentage" => 100}
            ]
          }
        }
      ]

      # Mock the poller functions
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: flag_definitions,
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: ~U[2023-01-01 00:00:00Z]
        }
      end)

      # Test with only_evaluate_locally: true
      result = FeatureFlags.check(:test_posthog_local, "local-only-flag", %{
        distinct_id: "user123",
        only_evaluate_locally: true
      })

      assert {:ok, true} = result
    end

    test "check/3 falls back to remote when local evaluation fails", %{config: config} do
      # Mock local evaluation to fail
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: [],  # No flags available locally
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: nil
        }
      end)

      # Mock remote API call
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :post, "/flags", opts ->
          assert opts[:json][:distinct_id] == "user123"
          assert opts[:params] == %{v: 2}

          {:ok, %{
            status: 200,
            body: %{
              "flags" => %{
                "remote-flag" => %{"enabled" => true}
              }
            }
          }}
      end)

      # Should fall back to remote evaluation
      result = FeatureFlags.check(:test_posthog_local, "remote-flag", "user123")

      assert {:ok, true} = result
    end

    test "check/3 returns error when only_evaluate_locally is true but local evaluation fails", %{config: config} do
      # Mock local evaluation to fail
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: [],  # No flags available locally
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: nil
        }
      end)

      # Should NOT fall back to remote when only_evaluate_locally is true
      result = FeatureFlags.check(:test_posthog_local, "missing-flag", %{
        distinct_id: "user123",
        only_evaluate_locally: true
      })

      assert {:error, error} = result
      assert %PostHog.Error{} = error
      assert String.contains?(error.message, "Local evaluation failed")
    end

    test "flags_for/2 uses local evaluation when available", %{config: config} do
      flag_definitions = [
        %{
          "key" => "flag1",
          "active" => true,
          "filters" => %{
            "groups" => [
              %{"properties" => [], "rollout_percentage" => 100}
            ]
          }
        },
        %{
          "key" => "flag2",
          "active" => true,
          "filters" => %{
            "groups" => [
              %{
                "properties" => [
                  %{
                    "key" => "plan",
                    "operator" => "exact",
                    "value" => "premium",
                    "type" => "person"
                  }
                ],
                "rollout_percentage" => 100
              }
            ]
          }
        }
      ]

      # Mock the poller functions
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: flag_definitions,
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: ~U[2023-01-01 00:00:00Z]
        }
      end)

      # Test getting all flags with person properties
      result = FeatureFlags.flags_for(:test_posthog_local, %{
        distinct_id: "user123",
        person_properties: %{"plan" => "premium"}
      })

      assert {:ok, flags} = result
      assert flags["flag1"]["enabled"] == true
      assert flags["flag2"]["enabled"] == true  # Should match the property condition
    end

    test "flags_for/2 with non-matching properties", %{config: config} do
      flag_definitions = [
        %{
          "key" => "premium-flag",
          "active" => true,
          "filters" => %{
            "groups" => [
              %{
                "properties" => [
                  %{
                    "key" => "plan",
                    "operator" => "exact",
                    "value" => "premium",
                    "type" => "person"
                  }
                ],
                "rollout_percentage" => 100
              }
            ]
          }
        }
      ]

      # Mock the poller functions
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: flag_definitions,
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: ~U[2023-01-01 00:00:00Z]
        }
      end)

      # Test with non-matching properties
      result = FeatureFlags.flags_for(:test_posthog_local, %{
        distinct_id: "user123",
        person_properties: %{"plan" => "basic"}  # Doesn't match "premium"
      })

      assert {:ok, flags} = result
      assert flags["premium-flag"]["enabled"] == false
    end

    test "multivariate flags work with local evaluation", %{config: config} do
      flag_definitions = [
        %{
          "key" => "multivariate-flag",
          "active" => true,
          "filters" => %{
            "groups" => [
              %{"properties" => [], "rollout_percentage" => 100}
            ],
            "multivariate" => %{
              "variants" => [
                %{"key" => "control", "rollout_percentage" => 50},
                %{"key" => "test", "rollout_percentage" => 50}
              ]
            }
          }
        }
      ]

      # Mock the poller functions
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: flag_definitions,
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: ~U[2023-01-01 00:00:00Z]
        }
      end)

      # Test multivariate flag
      result = FeatureFlags.check(:test_posthog_local, "multivariate-flag", "user123")

      assert {:ok, variant} = result
      assert variant in ["control", "test"]
    end

    test "variant override works with local evaluation", %{config: config} do
      flag_definitions = [
        %{
          "key" => "override-flag",
          "active" => true,
          "filters" => %{
            "groups" => [
              %{
                "properties" => [],
                "rollout_percentage" => 100,
                "variant" => "special_variant"
              }
            ]
          }
        }
      ]

      # Mock the poller functions
      expect(PostHog.FeatureFlags.Poller, :local_evaluation_enabled?, fn ^config -> true end)
      expect(PostHog.FeatureFlags.Poller, :get_feature_flags, fn ^config ->
        %{
          feature_flags: flag_definitions,
          group_type_mapping: %{},
          cohorts: %{},
          last_updated: ~U[2023-01-01 00:00:00Z]
        }
      end)

      # Test variant override
      result = FeatureFlags.check(:test_posthog_local, "override-flag", "user123")

      assert {:ok, "special_variant"} = result
    end
  end

  describe "local evaluation disabled" do
    test "falls back to remote evaluation when local evaluation is disabled" do
      config = %{
        enable_local_evaluation: false,  # Disabled
        personal_api_key: nil,
        supervisor_name: :test_posthog_remote,
        api_client: %PostHog.API.Client{module: PostHog.MockAPIClient, client: :mock},
        api_key: "phc_test_key"
      }

      # Mock the PostHog.config/1 function
      expect(PostHog, :config, fn :test_posthog_remote -> config end)

      # Mock remote API call
      expect(PostHog.MockAPIClient, :request, fn
        :mock, :post, "/flags", opts ->
          assert opts[:json][:distinct_id] == "user123"

          {:ok, %{
            status: 200,
            body: %{
              "flags" => %{
                "remote-only-flag" => %{"enabled" => true}
              }
            }
          }}
      end)

      # Should use remote evaluation
      result = FeatureFlags.check(:test_posthog_remote, "remote-only-flag", "user123")

      assert {:ok, true} = result
    end
  end
end
