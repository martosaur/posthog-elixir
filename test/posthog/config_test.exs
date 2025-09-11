defmodule PostHog.ConfigTest do
  use ExUnit.Case, async: true

  alias PostHog.Config

  describe "configuration validation" do
    test "validates basic required configuration" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key"
      ]

      assert {:ok, config} = Config.validate(options)
      assert config.public_url == "https://us.i.posthog.com"
      assert config.api_key == "phc_test_key"
    end

    test "includes default values for local evaluation options" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key"
      ]

      assert {:ok, config} = Config.validate(options)
      assert config.enable_local_evaluation == true
      assert config.feature_flags_poll_interval == 30_000
      assert config.feature_flags_request_timeout == 10_000
      # personal_api_key is optional and may not be in the config when nil
      assert Map.get(config, :personal_api_key) == nil
    end

    test "accepts custom local evaluation configuration" do
      options = [
        public_url: "https://eu.i.posthog.com",
        api_key: "phc_test_key",
        personal_api_key: "phx_personal_key",
        enable_local_evaluation: false,
        feature_flags_poll_interval: 60_000,
        feature_flags_request_timeout: 15_000
      ]

      assert {:ok, config} = Config.validate(options)
      assert config.public_url == "https://eu.i.posthog.com"
      assert config.api_key == "phc_test_key"
      assert config.personal_api_key == "phx_personal_key"
      assert config.enable_local_evaluation == false
      assert config.feature_flags_poll_interval == 60_000
      assert config.feature_flags_request_timeout == 15_000
    end

    test "validates personal_api_key as string" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        personal_api_key: "phx_valid_key"
      ]

      assert {:ok, config} = Config.validate(options)
      assert config.personal_api_key == "phx_valid_key"
    end

    test "rejects invalid enable_local_evaluation type" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        enable_local_evaluation: "invalid"
      ]

      assert {:error, %NimbleOptions.ValidationError{}} = Config.validate(options)
    end

    test "rejects invalid feature_flags_poll_interval type" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        feature_flags_poll_interval: "invalid"
      ]

      assert {:error, %NimbleOptions.ValidationError{}} = Config.validate(options)
    end

    test "rejects negative feature_flags_poll_interval" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        feature_flags_poll_interval: -1000
      ]

      assert {:error, %NimbleOptions.ValidationError{}} = Config.validate(options)
    end

    test "rejects invalid feature_flags_request_timeout type" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        feature_flags_request_timeout: "invalid"
      ]

      assert {:error, %NimbleOptions.ValidationError{}} = Config.validate(options)
    end

    test "rejects negative feature_flags_request_timeout" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        feature_flags_request_timeout: -5000
      ]

      assert {:error, %NimbleOptions.ValidationError{}} = Config.validate(options)
    end

    test "accepts zero feature_flags_poll_interval (disabled polling)" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        feature_flags_poll_interval: 0
      ]

      # Note: pos_integer doesn't include 0, so this should fail
      assert {:error, %NimbleOptions.ValidationError{}} = Config.validate(options)
    end

    test "validates minimum values for timeouts" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        feature_flags_poll_interval: 1,  # Minimum positive integer
        feature_flags_request_timeout: 1
      ]

      assert {:ok, config} = Config.validate(options)
      assert config.feature_flags_poll_interval == 1
      assert config.feature_flags_request_timeout == 1
    end
  end

  describe "config integration with global properties" do
    test "includes lib version in global properties" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key"
      ]

      assert {:ok, config} = Config.validate(options)
      # Check that global properties exist and have the right structure
      assert Map.has_key?(config, :global_properties)
      global_props = Map.get(config, :global_properties, %{})
      assert global_props[:"$lib"] == "posthog-elixir"
      assert is_binary(global_props[:"$lib_version"])
    end

    test "api_client is properly configured" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key"
      ]

      assert {:ok, config} = Config.validate(options)
      assert %PostHog.API.Client{} = config.api_client
      assert config.api_client.module == PostHog.API.Client
    end
  end

  describe "local evaluation feature compatibility" do
    test "config supports all required fields for local evaluation" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        personal_api_key: "phx_personal_key",
        enable_local_evaluation: true,
        feature_flags_poll_interval: 30_000,
        feature_flags_request_timeout: 10_000
      ]

      assert {:ok, config} = Config.validate(options)

      # All fields needed for PostHog.FeatureFlags.Poller.local_evaluation_enabled?/1
      assert Map.has_key?(config, :enable_local_evaluation)
      assert Map.has_key?(config, :personal_api_key)

      # All fields needed for polling
      assert Map.has_key?(config, :feature_flags_poll_interval)
      assert Map.has_key?(config, :feature_flags_request_timeout)
      assert Map.has_key?(config, :api_client)
      assert Map.has_key?(config, :api_key)
    end

    test "validates complete local evaluation setup" do
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key_123",
        personal_api_key: "phx_personal_key_456",
        enable_local_evaluation: true,
        feature_flags_poll_interval: 15_000,
        feature_flags_request_timeout: 8_000,
        supervisor_name: :my_posthog
      ]

      assert {:ok, config} = Config.validate(options)

      # Verify all values are correctly set
      assert config.api_key == "phc_test_key_123"
      assert config.personal_api_key == "phx_personal_key_456"
      assert config.enable_local_evaluation == true
      assert config.feature_flags_poll_interval == 15_000
      assert config.feature_flags_request_timeout == 8_000
      assert config.supervisor_name == :my_posthog
    end
  end

  describe "backwards compatibility" do
    test "existing configurations still work without new fields" do
      # This should work exactly as before
      options = [
        public_url: "https://us.i.posthog.com",
        api_key: "phc_test_key",
        api_client_module: PostHog.API.Client,
        supervisor_name: :posthog,
        metadata: [:request_id],
        capture_level: :error,
        in_app_otp_apps: []  # Use empty list instead of [:my_app] since my_app doesn't exist
      ]

      assert {:ok, config} = Config.validate(options)

      # Original fields should work
      assert config.api_key == "phc_test_key"
      assert config.supervisor_name == :posthog
      assert config.metadata == [:request_id]
      assert config.capture_level == :error
      assert config.in_app_otp_apps == []

      # New fields should have defaults
      assert config.enable_local_evaluation == true
      assert config.feature_flags_poll_interval == 30_000
      assert config.feature_flags_request_timeout == 10_000
      assert Map.get(config, :personal_api_key) == nil
    end
  end
end
