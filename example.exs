# PostHog Elixir SDK Example
#
# This script demonstrates various PostHog Elixir SDK capabilities including:
# - Basic event capture and user identification
# - Feature flag evaluation (remote only)
# - Context management
# - Special events (alias, group identify)
#
# Setup:
# 1. Run this script: POSTHOG_HOST=https://us.posthog.com POSTHOG_PROJECT_API_KEY=phc_... mix run example.exs
# 2. Choose from the interactive menu
#
# Note: This script must be run with `mix run example.exs` to ensure
# all dependencies are properly loaded.

defmodule PostHogExample do
  @moduledoc """
  Interactive example for PostHog Elixir SDK
  """

  @default_host "http://localhost:8000"

  def run do
    with :ok <- load_env_file(),
         {:ok, config} <- get_config(),
         :ok <- setup_posthog(config),
         :ok <- test_authentication() do
      show_menu_and_run()
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp get_config do
    case System.get_env("POSTHOG_PROJECT_API_KEY") do
      nil ->
        {:error, :missing_credentials}

      "" ->
        {:error, :empty_credentials}

      project_key ->
        host = System.get_env("POSTHOG_HOST", @default_host)
        {:ok, %{project_key: project_key, host: host}}
    end
  end

  defp setup_posthog(%{project_key: project_key, host: host}) do
    # Stop PostHog application if it's running
    Application.stop(:posthog)

    # Configure PostHog application environment
    Application.put_env(:posthog, :enable, true)
    Application.put_env(:posthog, :api_key, project_key)
    Application.put_env(:posthog, :public_url, host)

    # Start PostHog application with new configuration
    case Application.ensure_all_started(:posthog) do
      {:ok, _apps} ->
        # Give PostHog a moment to fully initialize
        Process.sleep(500)
        :ok
      {:error, reason} ->
        {:error, {:posthog_start_failed, reason}}
    end
  end

  defp test_authentication do
    IO.puts("🔑 Testing PostHog authentication...")

    case PostHog.FeatureFlags.flags_for("test_user") do
      {:ok, _flags} ->
        %{project_key: project_key, host: host} = get_stored_config()
        IO.puts("✅ Authentication successful!")
        IO.puts("   Project API Key: #{mask_api_key(project_key)}")
        IO.puts("   Host: #{host}\n\n")
        :ok

      {:error, reason} ->
        {:error, {:auth_failed, reason}}
    end
  rescue
    error -> {:error, {:auth_exception, error}}
  end

  defp show_menu_and_run do
    display_menu()

    choice = get_user_choice()
    execute_choice(choice)

    display_completion_message()
  end

  defp display_menu do
    IO.puts("🚀 PostHog Elixir SDK Demo - Choose an example to run:\n")

    [
      "1. Basic event capture examples",
      "2. Feature flag examples",
      "3. Context management examples",
      "4. Special events examples (alias, groups)",
      "5. Run all examples",
      "6. Exit"
    ]
    |> Enum.each(&IO.puts/1)
  end

  defp get_user_choice do
    IO.gets("\nEnter your choice (1-6): ")
    |> String.trim()
  end

  defp execute_choice(choice) do
    case choice do
      "1" -> run_basic_events()
      "2" -> run_feature_flags()
      "3" -> run_context_management()
      "4" -> run_special_events()
      "5" -> run_all_examples()
      "6" -> exit_gracefully()
      _ -> exit_with_error("Invalid choice. Please run again and select 1-6.")
    end
  end

  defp display_completion_message do
    # Flush any pending events before showing completion
    flush_events()

    separator = String.duplicate("=", 60)
    IO.puts(["\n", separator, "\n✅ Example completed!\n", separator])
  end

  defp load_env_file do
    env_path = Path.join(__DIR__, ".env")

    case File.read(env_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.each(&process_env_line/1)
        :ok

      {:error, :enoent} ->
        :ok  # .env file doesn't exist, which is fine

      {:error, reason} ->
        {:error, {:env_file_read_error, reason}}
    end
  end

  defp process_env_line(line) do
    line
    |> String.trim()
    |> parse_env_line()
    |> set_env_var()
  end

  defp parse_env_line(""), do: :skip
  defp parse_env_line("#" <> _), do: :skip

  defp parse_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> {:set, String.trim(key), String.trim(value)}
      _ -> :skip
    end
  end

  defp set_env_var({:set, key, value}) do
    unless System.get_env(key), do: System.put_env(key, value)
  end

  defp set_env_var(:skip), do: :ok

  # Helper functions for error handling and display
  defp handle_error(:missing_credentials) do
    IO.puts("❌ Missing PostHog credentials!")
    IO.puts("   Please set POSTHOG_PROJECT_API_KEY environment variable")
    IO.puts("   or copy .env.example to .env and fill in your values")
    System.halt(1)
  end

  defp handle_error(:empty_credentials) do
    IO.puts("❌ Empty PostHog credentials!")
    IO.puts("   Please set POSTHOG_PROJECT_API_KEY environment variable")
    IO.puts("   or copy .env.example to .env and fill in your values")
    System.halt(1)
  end

  defp handle_error({:auth_failed, reason}) do
    IO.puts("❌ Authentication failed!")
    IO.puts("   Error: #{inspect(reason)}")
    IO.puts("\n   Please check your credentials:")
    IO.puts("   - POSTHOG_PROJECT_API_KEY: Project API key from PostHog settings")
    IO.puts("   - POSTHOG_HOST: Your PostHog instance URL")
    IO.puts("")
    IO.puts("   💡 Common issues:")
    IO.puts("   - If you're using PostHog Cloud, use: https://us.i.posthog.com or https://eu.i.posthog.com")
    IO.puts("   - If you're using a local PostHog instance, it may have CSRF protection enabled")
    IO.puts("     which can interfere with API calls. Try using PostHog Cloud instead.")
    IO.puts("   - Ensure your API key starts with 'phc_' and is from your project settings")
    System.halt(1)
  end

  defp handle_error({:auth_exception, error}) do
    IO.puts("❌ Authentication failed!")
    IO.puts("   Error: #{inspect(error)}")
    System.halt(1)
  end

  defp handle_error({:posthog_start_failed, reason}) do
    IO.puts("❌ Failed to start PostHog application!")
    IO.puts("   Error: #{inspect(reason)}")
    IO.puts("\n   This might be due to missing dependencies or configuration issues.")
    IO.puts("   Make sure to run this script with: mix run example.exs")
    System.halt(1)
  end

  defp handle_error({:env_file_read_error, reason}) do
    IO.puts("❌ Failed to read .env file!")
    IO.puts("   Error: #{inspect(reason)}")
    System.halt(1)
  end

  defp handle_error(reason) do
    IO.puts("❌ An unexpected error occurred!")
    IO.puts("   Error: #{inspect(reason)}")
    System.halt(1)
  end

  defp get_stored_config do
    %{
      project_key: Application.get_env(:posthog, :api_key),
      host: Application.get_env(:posthog, :public_url)
    }
  end

  defp mask_api_key(api_key) when is_binary(api_key) do
    String.slice(api_key, 0..8) <> "..."
  end

  defp exit_gracefully do
    flush_events()
    IO.puts("👋 Goodbye!")
    System.halt(0)
  end

  defp exit_with_error(message) do
    IO.puts("❌ #{message}")
    System.halt(1)
  end

  defp run_basic_events do
    print_section_header("BASIC EVENT CAPTURE EXAMPLES")

    IO.puts("📊 Capturing events...")

    events = [
      {"event", %{distinct_id: "distinct_id", property1: "value", property2: "value"}},
      {"event2", %{distinct_id: "new_distinct_id", property1: "value", property2: "value"}},
      {"event-with-groups", %{
        "$groups" => %{"company" => "id:5"},
        distinct_id: "new_distinct_id",
        property1: "value",
        property2: "value",
      }}
    ]

    Enum.each(events, fn {event_name, properties} ->
      PostHog.capture(event_name, properties)
    end)

    IO.puts("✅ Events captured successfully!")
  end

  defp run_feature_flags do
    print_section_header("FEATURE FLAG EXAMPLES")

    IO.puts("🏁 Testing basic feature flags...")

    basic_flag_tests = [
      {"beta-feature", "distinct_id"},
      {"beta-feature", "new_distinct_id"}
    ]

    Enum.each(basic_flag_tests, fn {flag, user_id} ->
      check_and_display_flag(flag, user_id)
    end)

    # Check feature flag with groups
    check_and_display_flag("beta-feature-groups", %{
      distinct_id: "distinct_id",
      groups: %{"company" => "id:5"}
    }, "with groups")

    IO.puts("\n🌍 Testing location-based flags...")
    check_and_display_flag("test-flag", %{
      distinct_id: "random_id_12345",
      person_properties: %{"$geoip_city_name" => "Sydney"}
    }, "Sydney user")

    IO.puts("\n📋 Getting all flags...")
    get_and_display_all_flags("distinct_id_random_22")

    get_and_display_all_flags(%{
      distinct_id: "distinct_id_random_22",
      person_properties: %{"$geoip_city_name" => "Sydney"}
    }, "with properties")
  end

  defp run_context_management do
    print_section_header("CONTEXT MANAGEMENT EXAMPLES")

    IO.puts("🏷️ Testing context management...")
    IO.puts("You can set context properties that are automatically added to events.")

    # Demonstrate context workflow
    demonstrate_global_context()
    demonstrate_event_specific_context()
    demonstrate_context_enrichment()
    display_final_context()
  end

  defp demonstrate_global_context do
    PostHog.set_context(%{distinct_id: "context_user"})
    IO.puts("✅ Set global context with distinct_id")

    PostHog.capture("page_opened")
    IO.puts("✅ Event captured with context")
  end

  defp demonstrate_event_specific_context do
    PostHog.set_event_context("sensitive_event", %{"$process_person_profile" => false})
    IO.puts("✅ Set event-specific context")

    PostHog.capture("sensitive_event", %{action: "viewed_profile"})
    IO.puts("✅ Sensitive event captured with specific context")

    # Display contexts
    context = PostHog.get_context()
    event_context = PostHog.get_event_context("sensitive_event")

    IO.puts("Current global context: #{inspect(context)}")
    IO.puts("Context for 'sensitive_event': #{inspect(event_context)}")
  end

  defp demonstrate_context_enrichment do
    PostHog.set_context(%{
      user_plan: "premium",
      feature_enabled: true
    })

    PostHog.capture("feature_used", %{feature_name: "advanced_analytics"})
    IO.puts("✅ Event captured with enriched context")
  end

  defp display_final_context do
    final_context = PostHog.get_context()
    IO.puts("Final context: #{inspect(final_context)}")
  end

  defp run_special_events do
    print_section_header("SPECIAL EVENTS EXAMPLES")

    demonstrate_alias_creation()
    demonstrate_group_identification()
    demonstrate_additional_groups()
  end

  defp demonstrate_alias_creation do
    IO.puts("🔗 Creating alias...")

    PostHog.capture("$create_alias", %{
      distinct_id: "frontend_id",
      alias: "backend_id"
    })

    IO.puts("✅ Alias created: frontend_id -> backend_id")
  end

  defp demonstrate_group_identification do
    IO.puts("\n🏢 Group identification...")

    company_data = %{
      "$group_type" => "company",
      "$group_key" => "company_123",
      distinct_id: "group_admin_user",
      company_name: "Example Corp",
      employees: 50,
      plan: "enterprise"
    }

    PostHog.capture("$groupidentify", company_data)
    IO.puts("✅ Group identified: company_123")

    # Capture event associated with the group
    PostHog.capture("company_action", %{
      "$groups" => %{"company" => "company_123"},
      distinct_id: "user_in_company",
      action: "upgraded_plan"
    })

    IO.puts("✅ Event captured with group association")
  end

  defp demonstrate_additional_groups do
    IO.puts("\n📊 Additional group events...")

    team_data = %{
      "$group_type" => "team",
      "$group_key" => "engineering_team",
      distinct_id: "team_lead",
      team_name: "Engineering",
      team_size: 12,
      department: "Product"
    }

    PostHog.capture("$groupidentify", team_data)
    IO.puts("✅ Team group identified")

    # Event with multiple group associations
    multi_group_event = %{
      "$groups" => %{
        "company" => "company_123",
        "team" => "engineering_team"
      },
      distinct_id: "team_member",
      milestone: "shipped_v2"
    }

    PostHog.capture("team_milestone", multi_group_event)
    IO.puts("✅ Event with multiple group associations")
  end

  defp run_all_examples do
    IO.puts("\n🔄 Running all examples...")

    examples = [
      {"BASIC EVENTS", &run_basic_events_summary/0},
      {"FEATURE FLAGS", &run_feature_flags_summary/0},
      {"CONTEXT", &run_context_summary/0},
      {"SPECIAL EVENTS", &run_special_events_summary/0}
    ]

    Enum.each(examples, fn {title, fun} ->
      print_subsection_header(title)
      fun.()
    end)
  end

  defp run_basic_events_summary do
    IO.puts("📊 Capturing events...")
    PostHog.capture("event", %{
      distinct_id: "distinct_id",
      property1: "value",
      property2: "value"
    })
    IO.puts("✅ Basic events captured")
  end

  defp run_feature_flags_summary do
    IO.puts("🏁 Testing basic feature flags...")

    with_flag_result("beta-feature", "distinct_id", fn
      {:ok, result} -> IO.puts("beta-feature: #{inspect(result)}")
      {:error, _} -> IO.puts("beta-feature: error (flag may not exist)")
    end)

    with_flags_result("demo_user", fn
      {:ok, flags} -> IO.puts("All flags count: #{map_size(flags)}")
      {:error, _} -> IO.puts("Could not retrieve flags")
    end)
  end

  defp run_context_summary do
    IO.puts("🏷️ Testing context management...")
    PostHog.set_context(%{distinct_id: "demo_user", demo_run: "all_examples"})
    PostHog.capture("demo_completed")
    IO.puts("✅ Demo completed with context")
  end

  defp run_special_events_summary do
    IO.puts("🔗 Testing special events...")

    special_events = [
      {"$create_alias", %{distinct_id: "demo_frontend", alias: "demo_backend"}},
      {"$groupidentify", %{
        "$group_type" => "company",
        "$group_key" => "demo_company",
        distinct_id: "demo_admin",
      }}
    ]

    Enum.each(special_events, fn {event, data} ->
      PostHog.capture(event, data)
    end)

    IO.puts("✅ Special events completed")
  end

  # Helper functions for display formatting
  defp print_section_header(title) do
    separator = String.duplicate("=", 60)
    IO.puts(["\n", separator, "\n", title, "\n", separator])
  end

  defp print_subsection_header(title) do
    separator = String.duplicate("🔸", 20)
    IO.puts(["\n", separator, " ", title, " ", separator])
  end

  # Helper functions for feature flag operations
  defp check_and_display_flag(flag_name, user_or_params, description \\ nil) do
    result = PostHog.FeatureFlags.check(flag_name, user_or_params)
    display_flag_result(flag_name, result, description)
  end

  defp display_flag_result(flag_name, {:ok, result}, nil) do
    IO.puts("#{flag_name}: #{inspect(result)}")
  end

  defp display_flag_result(flag_name, {:ok, result}, description) do
    IO.puts("#{flag_name} for #{description}: #{inspect(result)}")
  end

  defp display_flag_result(flag_name, {:error, error}, description) do
    desc = if description, do: " (#{description})", else: ""
    IO.puts("Error checking #{flag_name}#{desc}: #{inspect(error)}")
  end

  defp get_and_display_all_flags(user_or_params, description \\ nil) do
    result = PostHog.FeatureFlags.flags_for(user_or_params)
    display_all_flags_result(result, description)
  end

  defp display_all_flags_result({:ok, flags}, nil) do
    IO.puts("All flags: #{inspect(flags)}")
  end

  defp display_all_flags_result({:ok, flags}, description) do
    IO.puts("All flags #{description}: #{inspect(flags)}")
  end

  defp display_all_flags_result({:error, error}, description) do
    desc = if description, do: " #{description}", else: ""
    IO.puts("Error getting all flags#{desc}: #{inspect(error)}")
  end

  # Helper functions for feature flag summaries
  defp with_flag_result(flag_name, user_id, callback) do
    flag_name
    |> PostHog.FeatureFlags.check(user_id)
    |> callback.()
  end

  defp with_flags_result(user_id, callback) do
    user_id
    |> PostHog.FeatureFlags.flags_for()
    |> callback.()
  end

  # Helper function to force flush all pending events
  defp flush_events() do
    IO.puts("🔄 Flushing pending events...")

    # Use the new public flush function with blocking enabled
    case PostHog.flush(blocking: true, timeout: 5_000) do
      {:ok, :flushed} ->
        IO.puts("✅ All events flushed successfully!")

      {:error, :timeout} ->
        IO.puts("⚠️ Flush timeout - some events may still be sending...")

      {:error, {:some_flushes_failed, details}} ->
        IO.puts("⚠️ Some flush operations failed:")
        Enum.each(details, fn detail ->
          IO.puts("   - #{inspect(detail)}")
        end)

      :ok ->
        IO.puts("✅ Flush triggered (non-blocking mode)!")
    end
  end
end

# Run the example
PostHogExample.run()
