defmodule PostHog.FeatureFlags do
  @type supervisor_name() :: PostHog.supervisor_name()
  @type distinct_id() :: PostHog.distinct_id()

  @doc """
  Make request to [`/flags`](https://posthog.com/docs/api/flags) API.

  This function is a thin wrapper over a client call and is useful as a building
  block to build your own `check/3`. For example, this is a preferred
  way to access remote config payload.

  ## Examples

  Make request to `/flags` API:

      PostHog.FeatureFlags.flags(%{distinct_id: "user123"})

  Make request to `/flags` API with additional body params:

      PostHog.FeatureFlags.flags(%{distinct_id: "my_distinct_id", groups: %{group_type: "group_id"}})

  Make request to `/flags` API through a named PostHog instance:

      PostHog.FeatureFlags.flags(MyPostHog, %{distinct_id: "user123"})
  """
  @spec flags(supervisor_name(), map()) ::
          PostHog.API.Client.response() | {:error, PostHog.Error.t()}
  def flags(name \\ PostHog, body) do
    config = PostHog.config(name)

    case PostHog.API.flags(config.api_client, body) do
      {:ok, %{status: 200, body: %{"flags" => _}}} = resp ->
        resp

      {:ok, %{status: 200, body: body}} ->
        {:error,
         %PostHog.UnexpectedResponseError{
           response: body,
           message: "Expected response body to have \"flags\" key"
         }}

      {:ok, resp} ->
        {:error, %PostHog.UnexpectedResponseError{response: resp, message: "Unexpected response"}}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def flags_for(distinct_id_or_body) when not is_atom(distinct_id_or_body),
    do: flags_for(PostHog, distinct_id_or_body)

  @doc """
  Get all feature flags.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  ## Examples

  Get all feature flags:

      PostHog.FeatureFlags.flags_for("user123")

  Get all feature flags with full request body:

      PostHog.FeatureFlags.flags_for(%{distinct_id: "user123", group: %{group_type: "group_id"}})

  Get all feature flags for `distinct_id` from the context:

      PostHog.set_context(%{distinct_id: "user123"})
      PostHog.FeatureFlags.flags_for()

  Get all feature flags through a named PostHog instance:

      PostHog.FeatureFlags.flags_for(MyPostHog, "foo")
  """
  @spec flags_for(supervisor_name(), distinct_id() | map() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  def flags_for(name \\ PostHog, distinct_id_or_body \\ nil) do
    config = PostHog.config(name)

    with {:ok, body} <- body_for_flags(distinct_id_or_body) do
      only_evaluate_locally = Map.get(body, :only_evaluate_locally, false)

      # Try local evaluation if enabled
      if only_evaluate_locally or PostHog.FeatureFlags.Poller.local_evaluation_enabled?(config) do
        case get_all_flags_locally(config, body) do
          {:ok, flags} -> {:ok, flags}
          {:error, _} when not only_evaluate_locally ->
            # Fall back to remote if local evaluation fails and not forced
            with {:ok, %{body: %{"flags" => flags}}} <- flags(name, body) do
              {:ok, flags}
            end
          {:error, reason} ->
            {:error, %PostHog.Error{message: "Local evaluation failed: #{inspect(reason)}"}}
        end
      else
        # Use remote evaluation
        with {:ok, %{body: %{"flags" => flags}}} <- flags(name, body) do
          {:ok, flags}
        end
      end
    end
  end

  @doc false
  def check(flag_name, distinct_id_or_body) when not is_atom(flag_name),
    do: check(PostHog, flag_name, distinct_id_or_body)

  @doc """
  Checks feature flag

  If there is a variant assigned, returns `{:ok, variant}`. Otherwise, `{:ok,
  true}` or `{:ok, false}`.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  This function will also
  [send](https://posthog.com/docs/api/flags#step-3-send-a-feature_flag_called-event)
  `$feature_flag_called` event and
  [set](https://posthog.com/docs/api/flags#step-2-include-feature-flag-information-when-capturing-events)
  `$feature/feature-flag-name` property in context.

  ## Options

  The `distinct_id_or_body` parameter can be:
  - A string with the distinct_id
  - A map with request options including:
    - `:distinct_id` - The user's distinct ID
    - `:person_properties` - Map of person properties for local evaluation
    - `:groups` - Map of group information
    - `:group_properties` - Map of group properties for local evaluation
    - `:only_evaluate_locally` - Boolean to force local-only evaluation

  ## Examples

  Check boolean feature flag for `distinct_id`:

      iex> PostHog.FeatureFlags.check("example-feature-flag-1", "user123")
      {:ok, true}

  Check multivariant feature flag for `distinct_id` in the current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.check("example-feature-flag-1")
      {:ok, "variant1"}

  Check feature flag with local evaluation only:

      iex> PostHog.FeatureFlags.check("example-feature-flag-1", %{
      ...>   distinct_id: "user123",
      ...>   person_properties: %{"country" => "US"},
      ...>   only_evaluate_locally: true
      ...> })
      {:ok, true}

  Check boolean feature flag through a named PostHog instance:

      PostHog.check(MyPostHog, "example-feature-flag-1", "user123")
  """
  @spec check(supervisor_name(), String.t(), distinct_id() | map() | nil) ::
          {:ok, boolean()} | {:ok, String.t()} | {:error, Exception.t()}
  def check(name \\ PostHog, flag_name, distinct_id_or_body \\ nil) do
    config = PostHog.config(name)

    with {:ok, %{distinct_id: distinct_id} = body} <- body_for_flags(distinct_id_or_body) do
      # Check if we should only evaluate locally
      only_evaluate_locally = Map.get(body, :only_evaluate_locally, false)

      # Try local evaluation first if enabled
      local_result =
        if not only_evaluate_locally and PostHog.FeatureFlags.Poller.local_evaluation_enabled?(config) do
          try_local_evaluation(config, flag_name, body)
        else
          nil
        end

      result = case {local_result, only_evaluate_locally} do
        {{:ok, value, true}, _} ->
          # Successfully evaluated locally
          {:ok, value}

        {_, true} ->
          # Only local evaluation requested but failed
          case try_local_evaluation(config, flag_name, body) do
            {:ok, value, _} -> {:ok, value}
            {:error, reason} -> {:error, %PostHog.Error{message: "Local evaluation failed: #{inspect(reason)}"}}
          end

        _ ->
          # Fall back to remote evaluation
          case flags(name, body) do
            {:ok, %{body: response_body}} ->
              parse_flag_response(response_body, flag_name)

            {:error, _} = error ->
              error
          end
      end

      # Track feature flag usage for debugging
      log_feature_flag_usage(name, distinct_id, flag_name, result)

      result
    end
  end

  @doc """
  Checks feature flag and returns the variant or raises on error.

  This is a wrapper around `check/3` that returns the variant directly
  or raises an exception on error. This follows the Elixir convention where
  functions ending with `!` raise exceptions instead of returning error tuples.

  > **Warning**: Use this function with care as it will raise an error if the feature flag
  > is not found or if there are any API errors. For more resilient code, use `check/3`
  > which returns `{:error, reason}` instead of raising.

  ## Examples

  Check feature flag and get the variant:

      iex> PostHog.FeatureFlags.check!("example-feature-flag-1", "user123")
      true

  Check multivariant feature flag for distinct_id in current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.check!("example-feature-flag-1")
      "variant1"

  Check feature flag through a named PostHog instance:

      iex> PostHog.FeatureFlags.check!(MyPostHog, "example-feature-flag-1", "user123")
      false

  Raises an error when feature flag is not found:

      iex> PostHog.FeatureFlags.check!("example-feature-flag-3", "user123")
      ** (PostHog.UnexpectedResponseError) Feature flag example-feature-flag-3 was not found in the response
  """
  @spec check!(supervisor_name(), String.t(), distinct_id() | map() | nil) :: boolean() | String.t() | no_return()
  def check!(name \\ PostHog, flag_name, distinct_id_or_body \\ nil) do
    case check(name, flag_name, distinct_id_or_body) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec log_feature_flag_usage(supervisor_name(), String.t(), String.t(), {:ok, boolean() | String.t()} | {:error, Exception.t()}) :: :ok
  defp log_feature_flag_usage(name, distinct_id, flag_name, result)
  defp log_feature_flag_usage(name, distinct_id, flag_name, {:ok, variant}) do
    PostHog.capture(name, "$feature_flag_called", %{
      distinct_id: distinct_id,
      "$feature_flag": flag_name,
      "$feature_flag_response": variant
    })

    PostHog.set_context(name, %{"$feature/#{flag_name}" => variant})
  end

  defp log_feature_flag_usage(_name, _distinct_id, _flag_name, {:error, _error}) do
    # Do nothing for error cases
    :ok
  end

  @doc false
  defp get_all_flags_locally(config, body) do
    %{feature_flags: flags} = PostHog.FeatureFlags.Poller.get_feature_flags(config)

    if Enum.empty?(flags) do
      {:error, :no_flags_available}
    else
      eval_options = %{
        distinct_id: Map.get(body, :distinct_id),
        person_properties: Map.get(body, :person_properties, %{}),
        groups: Map.get(body, :groups, %{}),
        group_properties: Map.get(body, :group_properties, %{}),
        only_evaluate_locally: true
      }

      # Evaluate all flags locally
      evaluated_flags =
        flags
        |> Enum.map(fn flag ->
          flag_key = Map.get(flag, "key")
          case PostHog.FeatureFlags.Evaluator.evaluate_flag(config, flag_key, eval_options) do
            {:ok, value, _} -> {flag_key, %{"enabled" => value != false, "variant" => (if is_binary(value), do: value, else: nil)}}
            {:error, _} -> {flag_key, %{"enabled" => false, "variant" => nil}}
          end
        end)
        |> Map.new()

      {:ok, evaluated_flags}
    end
  end

  @doc false
  defp try_local_evaluation(config, flag_name, body) do
    eval_options = %{
      distinct_id: Map.get(body, :distinct_id),
      person_properties: Map.get(body, :person_properties, %{}),
      groups: Map.get(body, :groups, %{}),
      group_properties: Map.get(body, :group_properties, %{}),
      only_evaluate_locally: Map.get(body, :only_evaluate_locally, false)
    }

    PostHog.FeatureFlags.Evaluator.evaluate_flag(config, flag_name, eval_options)
  end

  @doc false
  defp parse_flag_response(response_body, flag_name) do
    case response_body do
      %{"flags" => %{^flag_name => %{"variant" => variant}}} when not is_nil(variant) ->
        {:ok, variant}

      %{"flags" => %{^flag_name => %{"enabled" => true}}} ->
        {:ok, true}

      %{"flags" => %{^flag_name => _}} ->
        {:ok, false}

      %{"flags" => _} ->
        {:error,
         %PostHog.UnexpectedResponseError{
           response: response_body,
           message: "Feature flag #{flag_name} was not found in the response"
         }}
    end
  end

  @doc false
  defp body_for_flags(distinct_id_or_body) do
    case distinct_id_or_body do
      %{distinct_id: _distinct_id} = body ->
        {:ok, body}

      nil ->
        case PostHog.get_context() do
          %{distinct_id: distinct_id} ->
            {:ok, %{distinct_id: distinct_id}}

          _context ->
            {:error,
             %PostHog.Error{
               message:
                 "distinct_id is required but wasn't explicitely provided or found in the context"
             }}
        end

      distinct_id when is_binary(distinct_id) ->
        {:ok, %{distinct_id: distinct_id}}
    end
  end
end
