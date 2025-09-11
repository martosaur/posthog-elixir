defmodule PostHog.FeatureFlags.Evaluator do
  @moduledoc """
  Local evaluation logic for PostHog feature flags.

  This module handles the evaluation of feature flags locally without making API requests,
  using the cached feature flag definitions from the Poller.
  """

  require Logger

  alias PostHog.Config
  alias PostHog.FeatureFlags.Poller

  @typedoc "Options for evaluating a feature flag"
  @type eval_options() :: %{
          distinct_id: String.t(),
          person_properties: map(),
          groups: map(),
          group_properties: map(),
          only_evaluate_locally: boolean()
        }

  @typedoc "Result of a feature flag evaluation"
  @type eval_result() :: {:ok, boolean() | String.t(), boolean()} | {:error, any()}

  @doc """
  Evaluate a feature flag locally.

  Returns `{:ok, value, locally_evaluated}` where:
  - `value` is the feature flag result (boolean or variant string)
  - `locally_evaluated` indicates if the flag was evaluated locally

  Returns `{:error, reason}` if evaluation fails.
  """
  @spec evaluate_flag(Config.config(), String.t(), eval_options()) :: eval_result()
  def evaluate_flag(config, flag_key, options) do
    if Poller.local_evaluation_enabled?(config) do
      case Poller.get_feature_flags(config) do
        %{feature_flags: flags, group_type_mapping: group_mapping, cohorts: cohorts}
        when flags != [] ->
          evaluate_flag_locally(flag_key, flags, group_mapping, cohorts, options)

        %{last_updated: nil} ->
          {:error, :flags_not_loaded}

        %{feature_flags: []} ->
          {:error, :no_flags_available}
      end
    else
      {:error, :local_evaluation_disabled}
    end
  end

  @doc """
  Check if a feature flag can be evaluated locally.
  """
  @spec can_evaluate_locally?(Config.config(), String.t()) :: boolean()
  def can_evaluate_locally?(config, flag_key) do
    if Poller.local_evaluation_enabled?(config) do
      %{feature_flags: flags} = Poller.get_feature_flags(config)

      find_flag_definition(flags, flag_key) != nil
    else
      false
    end
  end

  ## Private Functions

  @spec evaluate_flag_locally(String.t(), list(map()), map(), map(), eval_options()) :: eval_result()
  defp evaluate_flag_locally(flag_key, flags, group_mapping, cohorts, options) do
    case find_flag_definition(flags, flag_key) do
      nil ->
        {:error, :flag_not_found}

      flag_definition ->
        try do
          result = compute_flag_value(flag_definition, group_mapping, cohorts, options)
          {:ok, result, true}
        rescue
          error ->
            Logger.warning("[PostHog.FeatureFlags.Evaluator] Error evaluating flag #{flag_key}: #{inspect(error)}")
            {:error, {:evaluation_error, error}}
        end
    end
  end

  @spec find_flag_definition(list(map()), String.t()) :: map() | nil
  defp find_flag_definition(flags, flag_key) do
    Enum.find(flags, fn flag -> Map.get(flag, "key") == flag_key end)
  end

  @spec compute_flag_value(map(), map(), map(), eval_options()) :: boolean() | String.t()
  defp compute_flag_value(flag_definition, group_mapping, cohorts, options) do
    # Check if flag is active
    if Map.get(flag_definition, "active", false) do
      filters = Map.get(flag_definition, "filters", %{})

      # Get multivariate config if any
      multivariate = Map.get(filters, "multivariate")

      # Evaluate conditions
      case evaluate_conditions(filters, group_mapping, cohorts, flag_definition, options) do
        {:match, variant_override} when not is_nil(variant_override) ->
          variant_override

        {:match, _} when not is_nil(multivariate) ->
          evaluate_multivariate(multivariate, options.distinct_id, flag_definition)

        {:match, _} ->
          true

        :no_match ->
          false
      end
    else
      false
    end
  end

  @spec evaluate_conditions(map(), map(), map(), map(), eval_options()) :: {:match, String.t() | nil} | :no_match
  defp evaluate_conditions(filters, group_mapping, cohorts, flag_definition, options) do
    groups = Map.get(filters, "groups", [])

    # If no groups defined, the flag should return false (no match)
    # This matches the Python SDK behavior where empty conditions result in False
    if Enum.empty?(groups) do
      :no_match
    else
      # Check each condition group - if any matches, return match
      case find_matching_group(groups, group_mapping, cohorts, flag_definition, options) do
        {:match, variant} -> {:match, variant}
        :no_match -> :no_match
      end
    end
  end

  @spec find_matching_group(list(map()), map(), map(), map(), eval_options()) :: {:match, String.t() | nil} | :no_match
  defp find_matching_group(groups, group_mapping, cohorts, flag_definition, options) do
    Enum.reduce_while(groups, :no_match, fn group, _acc ->
      case evaluate_group(group, group_mapping, cohorts, flag_definition, options) do
        {:match, variant} -> {:halt, {:match, variant}}
        :no_match -> {:cont, :no_match}
      end
    end)
  end

  @spec evaluate_group(map(), map(), map(), map(), eval_options()) :: {:match, String.t() | nil} | :no_match
  defp evaluate_group(group, group_mapping, cohorts, flag_definition, options) do
    properties = Map.get(group, "properties", [])
    rollout_percentage = Map.get(group, "rollout_percentage")
    variant = Map.get(group, "variant")

    # Evaluate all property conditions
    properties_match = Enum.all?(properties, fn property ->
      evaluate_property(property, group_mapping, cohorts, options)
    end)

    if properties_match do
      # Check rollout percentage if specified
      if is_nil(rollout_percentage) or check_rollout(rollout_percentage, options.distinct_id, flag_definition) do
        {:match, variant}
      else
        :no_match
      end
    else
      :no_match
    end
  end

  @spec evaluate_property(map(), map(), map(), eval_options()) :: boolean()
  defp evaluate_property(property, _group_mapping, _cohorts, options) do
    key = Map.get(property, "key")
    operator = Map.get(property, "operator")
    value = Map.get(property, "value")
    type = Map.get(property, "type", "person")

    person_value = case type do
      "person" -> Map.get(options.person_properties, key)
      _ -> nil  # Group properties not fully implemented yet
    end

    evaluate_operator(operator, person_value, value)
  end

  @spec evaluate_operator(String.t(), any(), any()) :: boolean()
  defp evaluate_operator("exact", person_value, expected_value) do
    person_value == expected_value
  end

  defp evaluate_operator("is_not", person_value, expected_value) do
    person_value != expected_value
  end

  defp evaluate_operator("icontains", person_value, expected_value) when is_binary(person_value) and is_binary(expected_value) do
    String.contains?(String.downcase(person_value), String.downcase(expected_value))
  end

  defp evaluate_operator("not_icontains", person_value, expected_value) when is_binary(person_value) and is_binary(expected_value) do
    not String.contains?(String.downcase(person_value), String.downcase(expected_value))
  end

  defp evaluate_operator("gt", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value > expected_value
  end

  defp evaluate_operator("gte", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value >= expected_value
  end

  defp evaluate_operator("lt", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value < expected_value
  end

  defp evaluate_operator("lte", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value <= expected_value
  end

  defp evaluate_operator("is_set", person_value, _expected_value) do
    not is_nil(person_value)
  end

  defp evaluate_operator("is_not_set", person_value, _expected_value) do
    is_nil(person_value)
  end

  # Default case for unknown operators
  defp evaluate_operator(_operator, _person_value, _expected_value) do
    false
  end

  @spec check_rollout(float(), String.t(), map()) :: boolean()
  defp check_rollout(rollout_percentage, distinct_id, flag_definition) when is_number(rollout_percentage) do
    # Use the same hash algorithm as Python SDK
    flag_key = Map.get(flag_definition, "key", "")
    hash_value = posthog_hash(flag_key, distinct_id)

    # Python SDK: if hash > (rollout_percentage / 100) then False, else True
    # So we return: hash <= (rollout_percentage / 100)
    hash_value <= (rollout_percentage / 100.0)
  end

  defp check_rollout(_rollout_percentage, _distinct_id, _flag_definition), do: false

  @spec evaluate_multivariate(map(), String.t(), map()) :: String.t() | boolean()
  defp evaluate_multivariate(multivariate, distinct_id, flag_definition) do
    variants = Map.get(multivariate, "variants", [])

    if Enum.empty?(variants) do
      # No variants defined, return boolean true
      true
    else
      # Use PostHog's variant selection algorithm
      flag_key = Map.get(flag_definition, "key", "")
      hash_value = posthog_hash(flag_key, distinct_id, "variant")

      # Find the variant based on rollout percentages using lookup table approach
      variant = find_variant_from_hash(variants, hash_value)
      variant || true
    end
  end

  # PostHog hash function - matches Python SDK exactly
  @spec posthog_hash(String.t(), String.t(), String.t()) :: float()
  defp posthog_hash(key, distinct_id, salt \\ "") do
    hash_key = "#{key}.#{distinct_id}#{salt}"
    hash_value = :crypto.hash(:sha, hash_key)

    # Take first 60 bits like Python SDK (first 7.5 bytes)
    <<hash_int::60, _::bitstring>> = hash_value

    # Convert to float 0.0-1.0 using same scale as Python
    long_scale = 0xFFFFFFFFFFFFFFF  # 15 F's = 2^60 - 1
    hash_int / long_scale
  end

  @spec find_variant_from_hash(list(map()), float()) :: String.t() | nil
  defp find_variant_from_hash(variants, hash_value) do
    # Build lookup table like Python SDK
    lookup_table = build_variant_lookup_table(variants)

    Enum.find_value(lookup_table, fn variant ->
      if hash_value >= variant.value_min and hash_value < variant.value_max do
        variant.key
      end
    end)
  end

  @spec build_variant_lookup_table(list(map())) :: list(map())
  defp build_variant_lookup_table(variants) do
    {_, lookup_table} =
      Enum.reduce(variants, {0.0, []}, fn variant, {acc_percentage, table} ->
        rollout_percentage = Map.get(variant, "rollout_percentage", 0)
        key = Map.get(variant, "key")

        value_min = acc_percentage / 100.0
        value_max = (acc_percentage + rollout_percentage) / 100.0

        entry = %{key: key, value_min: value_min, value_max: value_max}
        {acc_percentage + rollout_percentage, [entry | table]}
      end)

    Enum.reverse(lookup_table)
  end
end
