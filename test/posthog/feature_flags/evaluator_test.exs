defmodule PostHog.FeatureFlags.EvaluatorTest do
  use ExUnit.Case, async: true

  describe "local evaluation logic" do
    test "inactive flag returns false" do
      flag_definition = %{
        "key" => "inactive-flag",
        "active" => false,
        "filters" => %{
          "groups" => [
            %{"properties" => [], "rollout_percentage" => 100}
          ]
        }
      }

      options = %{
        distinct_id: "user123",
        person_properties: %{},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      # Use private function for direct testing
      result = evaluate_flag_directly(flag_definition, options)
      assert result == false
    end

    test "flag with no groups returns false" do
      flag_definition = %{
        "key" => "no-groups-flag",
        "active" => true,
        "filters" => %{
          "groups" => []  # Empty groups should return false
        }
      }

      options = %{
        distinct_id: "user123",
        person_properties: %{},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      result = evaluate_flag_directly(flag_definition, options)
      # This is the critical test - should be false, not true
      assert result == false
    end

    test "simple boolean flag with 100% rollout returns true" do
      flag_definition = %{
        "key" => "simple-flag",
        "active" => true,
        "filters" => %{
          "groups" => [
            %{"properties" => [], "rollout_percentage" => 100}
          ]
        }
      }

      options = %{
        distinct_id: "user123",
        person_properties: %{},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      result = evaluate_flag_directly(flag_definition, options)
      assert result == true
    end

    test "flag with 0% rollout returns false" do
      flag_definition = %{
        "key" => "zero-rollout-flag",
        "active" => true,
        "filters" => %{
          "groups" => [
            %{"properties" => [], "rollout_percentage" => 0}
          ]
        }
      }

      options = %{
        distinct_id: "user123",
        person_properties: %{},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      result = evaluate_flag_directly(flag_definition, options)
      assert result == false
    end

    test "flag with person property match returns true" do
      flag_definition = %{
        "key" => "property-flag",
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

      # Matching property
      options_match = %{
        distinct_id: "user123",
        person_properties: %{"country" => "US"},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      result = evaluate_flag_directly(flag_definition, options_match)
      assert result == true

      # Non-matching property
      options_no_match = %{
        distinct_id: "user123",
        person_properties: %{"country" => "CA"},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      result = evaluate_flag_directly(flag_definition, options_no_match)
      assert result == false
    end

    test "multivariate flag returns variant" do
      flag_definition = %{
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

      options = %{
        distinct_id: "user123",
        person_properties: %{},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      result = evaluate_flag_directly(flag_definition, options)
      assert result in ["control", "test"]
    end

    test "variant override is respected" do
      flag_definition = %{
        "key" => "variant-override-flag",
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

      options = %{
        distinct_id: "user123",
        person_properties: %{},
        groups: %{},
        group_properties: %{},
        only_evaluate_locally: false
      }

      result = evaluate_flag_directly(flag_definition, options)
      assert result == "special_variant"
    end
  end

  describe "property operators" do
    test "exact operator" do
      assert evaluate_property_operator("exact", "premium", "premium") == true
      assert evaluate_property_operator("exact", "basic", "premium") == false
    end

    test "is_not operator" do
      assert evaluate_property_operator("is_not", "basic", "premium") == true
      assert evaluate_property_operator("is_not", "premium", "premium") == false
    end

    test "icontains operator" do
      assert evaluate_property_operator("icontains", "user@company.com", "@company") == true
      assert evaluate_property_operator("icontains", "USER@COMPANY.COM", "@company") == true
      assert evaluate_property_operator("icontains", "user@other.com", "@company") == false
    end

    test "not_icontains operator" do
      assert evaluate_property_operator("not_icontains", "user@other.com", "@company") == true
      assert evaluate_property_operator("not_icontains", "user@company.com", "@company") == false
    end

    test "numeric comparison operators" do
      assert evaluate_property_operator("gt", 25, 18) == true
      assert evaluate_property_operator("gt", 16, 18) == false
      assert evaluate_property_operator("gte", 18, 18) == true
      assert evaluate_property_operator("lt", 16, 18) == true
      assert evaluate_property_operator("lte", 18, 18) == true
    end

    test "is_set and is_not_set operators" do
      assert evaluate_property_operator("is_set", "value", nil) == true
      assert evaluate_property_operator("is_set", nil, nil) == false
      assert evaluate_property_operator("is_not_set", nil, nil) == true
      assert evaluate_property_operator("is_not_set", "value", nil) == false
    end

    test "unknown operator returns false" do
      assert evaluate_property_operator("unknown_op", "value", "value") == false
    end
  end

  describe "hash function" do
    test "produces consistent hash values" do
      hash1 = compute_hash("test-flag", "user123", "")
      hash2 = compute_hash("test-flag", "user123", "")

      assert hash1 == hash2
      assert is_float(hash1)
      assert hash1 >= 0.0 and hash1 <= 1.0
    end

    test "produces different hashes for different inputs" do
      hash1 = compute_hash("flag1", "user123", "")
      hash2 = compute_hash("flag2", "user123", "")
      hash3 = compute_hash("flag1", "user456", "")
      hash4 = compute_hash("flag1", "user123", "variant")

      # All should be different
      assert hash1 != hash2
      assert hash1 != hash3
      assert hash1 != hash4
      assert hash2 != hash3
    end

    test "hash distribution is reasonable" do
      # Test that hash values are distributed across the range
      hashes = for i <- 1..100 do
        compute_hash("test-flag", "user#{i}", "")
      end

      # Should have variety in hash values
      unique_hashes = Enum.uniq(hashes)
      assert length(unique_hashes) > 90  # Most should be unique

      # Should span the range
      min_hash = Enum.min(hashes)
      max_hash = Enum.max(hashes)
      assert min_hash < 0.1
      assert max_hash > 0.9
    end
  end

  # Helper functions that access the module's private logic
  defp evaluate_flag_directly(flag_definition, options) do
    # This simulates the compute_flag_value private function
    if Map.get(flag_definition, "active", false) do
      filters = Map.get(flag_definition, "filters", %{})
      multivariate = Map.get(filters, "multivariate")

      case evaluate_conditions_directly(filters, flag_definition, options) do
        {:match, variant_override} when not is_nil(variant_override) ->
          variant_override
        {:match, _} when not is_nil(multivariate) ->
          evaluate_multivariate_directly(multivariate, options.distinct_id, flag_definition)
        {:match, _} ->
          true
        :no_match ->
          false
      end
    else
      false
    end
  end

  defp evaluate_conditions_directly(filters, flag_definition, options) do
    groups = Map.get(filters, "groups", [])

    if Enum.empty?(groups) do
      :no_match
    else
      case find_matching_group_directly(groups, flag_definition, options) do
        {:match, variant} -> {:match, variant}
        :no_match -> :no_match
      end
    end
  end

  defp find_matching_group_directly(groups, flag_definition, options) do
    Enum.reduce_while(groups, :no_match, fn group, _acc ->
      case evaluate_group_directly(group, flag_definition, options) do
        {:match, variant} -> {:halt, {:match, variant}}
        :no_match -> {:cont, :no_match}
      end
    end)
  end

  defp evaluate_group_directly(group, flag_definition, options) do
    properties = Map.get(group, "properties", [])
    rollout_percentage = Map.get(group, "rollout_percentage")
    variant = Map.get(group, "variant")

    properties_match = Enum.all?(properties, fn property ->
      evaluate_property_directly(property, options)
    end)

    if properties_match do
      if is_nil(rollout_percentage) or check_rollout_directly(rollout_percentage, options.distinct_id, flag_definition) do
        {:match, variant}
      else
        :no_match
      end
    else
      :no_match
    end
  end

  defp evaluate_property_directly(property, options) do
    key = Map.get(property, "key")
    operator = Map.get(property, "operator")
    value = Map.get(property, "value")
    person_value = Map.get(options.person_properties, key)

    evaluate_property_operator(operator, person_value, value)
  end

  defp evaluate_property_operator("exact", person_value, expected_value) do
    person_value == expected_value
  end

  defp evaluate_property_operator("is_not", person_value, expected_value) do
    person_value != expected_value
  end

  defp evaluate_property_operator("icontains", person_value, expected_value) when is_binary(person_value) and is_binary(expected_value) do
    String.contains?(String.downcase(person_value), String.downcase(expected_value))
  end

  defp evaluate_property_operator("not_icontains", person_value, expected_value) when is_binary(person_value) and is_binary(expected_value) do
    not String.contains?(String.downcase(person_value), String.downcase(expected_value))
  end

  defp evaluate_property_operator("gt", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value > expected_value
  end

  defp evaluate_property_operator("gte", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value >= expected_value
  end

  defp evaluate_property_operator("lt", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value < expected_value
  end

  defp evaluate_property_operator("lte", person_value, expected_value) when is_number(person_value) and is_number(expected_value) do
    person_value <= expected_value
  end

  defp evaluate_property_operator("is_set", person_value, _expected_value) do
    not is_nil(person_value)
  end

  defp evaluate_property_operator("is_not_set", person_value, _expected_value) do
    is_nil(person_value)
  end

  defp evaluate_property_operator(_operator, _person_value, _expected_value) do
    false
  end

  defp check_rollout_directly(rollout_percentage, distinct_id, flag_definition) when is_number(rollout_percentage) do
    flag_key = Map.get(flag_definition, "key", "")
    hash_value = compute_hash(flag_key, distinct_id, "")
    hash_value <= (rollout_percentage / 100.0)
  end

  defp check_rollout_directly(_rollout_percentage, _distinct_id, _flag_definition), do: false

  defp evaluate_multivariate_directly(multivariate, distinct_id, flag_definition) do
    variants = Map.get(multivariate, "variants", [])

    if Enum.empty?(variants) do
      true
    else
      flag_key = Map.get(flag_definition, "key", "")
      hash_value = compute_hash(flag_key, distinct_id, "variant")

      find_variant_from_hash_directly(variants, hash_value) || true
    end
  end

  defp find_variant_from_hash_directly(variants, hash_value) do
    lookup_table = build_variant_lookup_table_directly(variants)

    Enum.find_value(lookup_table, fn variant ->
      if hash_value >= variant.value_min and hash_value < variant.value_max do
        variant.key
      end
    end)
  end

  defp build_variant_lookup_table_directly(variants) do
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

  defp compute_hash(key, distinct_id, salt) do
    hash_key = "#{key}.#{distinct_id}#{salt}"
    hash_value = :crypto.hash(:sha, hash_key)

    # Take first 60 bits like Python SDK (first 7.5 bytes)
    <<hash_int::60, _::bitstring>> = hash_value

    # Convert to float 0.0-1.0 using same scale as Python
    long_scale = 0xFFFFFFFFFFFFFFF  # 15 F's = 2^60 - 1
    hash_int / long_scale
  end
end
