require_relative "../test_helper"
require_relative "./json_schema_validator"
require "json"

class JsonSchemaValidatorTest < Minitest::Test
  V = JsonSchemaValidator

  FIXTURE_ROOT = File.expand_path("../fixtures/codex_schema", __dir__)

  def load_fixture(rel)
    JSON.parse(File.read(File.join(FIXTURE_ROOT, rel)))
  end

  # --- type ----------------------------------------------------------

  def test_type_string_accepts_string
    assert_empty V.validate({ "type" => "string" }, "hello")
  end

  def test_type_string_rejects_integer
    errors = V.validate({ "type" => "string" }, 42)
    assert_equal 1, errors.size
    assert_match(/expected type/, errors.first[:message])
    assert_equal "/", errors.first[:path]
  end

  def test_type_integer_accepts_integer
    assert_empty V.validate({ "type" => "integer" }, 42)
  end

  def test_type_integer_accepts_float_without_fraction
    assert_empty V.validate({ "type" => "integer" }, 42.0)
  end

  def test_type_integer_rejects_float_with_fraction
    refute_empty V.validate({ "type" => "integer" }, 42.5)
  end

  def test_type_number_accepts_integer_and_float
    assert_empty V.validate({ "type" => "number" }, 42)
    assert_empty V.validate({ "type" => "number" }, 42.5)
  end

  def test_type_number_rejects_string
    refute_empty V.validate({ "type" => "number" }, "42")
  end

  def test_type_boolean_accepts_only_true_or_false
    assert_empty V.validate({ "type" => "boolean" }, true)
    assert_empty V.validate({ "type" => "boolean" }, false)
    refute_empty V.validate({ "type" => "boolean" }, 1)
    refute_empty V.validate({ "type" => "boolean" }, "true")
  end

  def test_type_array_accepts_array
    assert_empty V.validate({ "type" => "array" }, [1, 2, 3])
  end

  def test_type_array_rejects_hash
    refute_empty V.validate({ "type" => "array" }, { "a" => 1 })
  end

  def test_type_object_accepts_hash
    assert_empty V.validate({ "type" => "object" }, { "a" => 1 })
  end

  def test_type_null_accepts_nil
    assert_empty V.validate({ "type" => "null" }, nil)
  end

  def test_type_null_rejects_false
    refute_empty V.validate({ "type" => "null" }, false)
  end

  def test_type_union_accepts_either_member
    schema = { "type" => ["string", "null"] }
    assert_empty V.validate(schema, "hi")
    assert_empty V.validate(schema, nil)
  end

  def test_type_union_rejects_non_member
    schema = { "type" => ["string", "null"] }
    refute_empty V.validate(schema, 42)
  end

  # --- required ------------------------------------------------------

  def test_required_passes_when_all_present
    schema = { "type" => "object", "required" => ["a", "b"] }
    assert_empty V.validate(schema, { "a" => 1, "b" => 2 })
  end

  def test_required_reports_missing_keys
    schema = { "type" => "object", "required" => ["a", "b"] }
    errors = V.validate(schema, { "a" => 1 })
    assert_equal 1, errors.size
    assert_match(/missing required property "b"/, errors.first[:message])
  end

  # --- enum / const --------------------------------------------------

  def test_enum_accepts_listed_value
    assert_empty V.validate({ "enum" => ["accept", "decline"] }, "accept")
  end

  def test_enum_rejects_unlisted_value
    errors = V.validate({ "enum" => ["accept", "decline"] }, "approved")
    refute_empty errors
    assert_match(/is not in enum/, errors.first[:message])
  end

  def test_const_accepts_match
    assert_empty V.validate({ "const" => "v2" }, "v2")
  end

  def test_const_rejects_mismatch
    refute_empty V.validate({ "const" => "v2" }, "v1")
  end

  # --- properties / additionalProperties ----------------------------

  def test_properties_validates_each_named_property
    schema = {
      "type" => "object",
      "properties" => {
        "name" => { "type" => "string" },
        "age"  => { "type" => "integer" }
      }
    }
    assert_empty V.validate(schema, { "name" => "Ada", "age" => 36 })
    errors = V.validate(schema, { "name" => "Ada", "age" => "thirty-six" })
    assert_equal 1, errors.size
    assert_equal "/age", errors.first[:path]
  end

  def test_additional_properties_false_rejects_extras
    schema = {
      "type" => "object",
      "properties" => { "name" => { "type" => "string" } },
      "additionalProperties" => false
    }
    errors = V.validate(schema, { "name" => "Ada", "extra" => 1 })
    assert_equal 1, errors.size
    assert_match(/additional property "extra"/, errors.first[:message])
  end

  def test_additional_properties_true_allows_extras
    schema = {
      "type" => "object",
      "properties" => { "name" => { "type" => "string" } },
      "additionalProperties" => true
    }
    assert_empty V.validate(schema, { "name" => "Ada", "anything" => [1, 2] })
  end

  def test_additional_properties_schema_validates_extras
    schema = {
      "type" => "object",
      "properties" => {},
      "additionalProperties" => { "type" => "string" }
    }
    assert_empty V.validate(schema, { "a" => "x", "b" => "y" })
    refute_empty V.validate(schema, { "a" => "x", "b" => 42 })
  end

  # --- items ---------------------------------------------------------

  def test_items_validates_each_element
    schema = { "type" => "array", "items" => { "type" => "integer" } }
    assert_empty V.validate(schema, [1, 2, 3])
    errors = V.validate(schema, [1, "two", 3])
    assert_equal 1, errors.size
    assert_equal "/1", errors.first[:path]
  end

  # --- oneOf / anyOf / allOf ----------------------------------------

  def test_one_of_passes_when_exactly_one_matches
    schema = {
      "oneOf" => [
        { "type" => "string" },
        { "type" => "integer" }
      ]
    }
    assert_empty V.validate(schema, "hi")
    assert_empty V.validate(schema, 42)
  end

  def test_one_of_fails_when_no_branch_matches
    schema = { "oneOf" => [{ "type" => "string" }, { "type" => "integer" }] }
    errors = V.validate(schema, true)
    assert_equal 1, errors.size
    assert_match(/did not match any of the 2 oneOf/, errors.first[:message])
  end

  def test_one_of_fails_when_multiple_branches_match
    schema = {
      "oneOf" => [
        { "type" => "integer" },
        { "type" => "number" }
      ]
    }
    errors = V.validate(schema, 42)
    assert_equal 1, errors.size
    assert_match(/matched 2 of the 2 oneOf/, errors.first[:message])
  end

  def test_any_of_passes_when_any_match
    schema = { "anyOf" => [{ "type" => "string" }, { "type" => "null" }] }
    assert_empty V.validate(schema, "hi")
    assert_empty V.validate(schema, nil)
  end

  def test_any_of_fails_when_none_match
    schema = { "anyOf" => [{ "type" => "string" }, { "type" => "null" }] }
    refute_empty V.validate(schema, 42)
  end

  def test_all_of_passes_when_all_match
    schema = {
      "allOf" => [
        { "type" => "object" },
        { "required" => ["a"] }
      ]
    }
    assert_empty V.validate(schema, { "a" => 1 })
  end

  def test_all_of_fails_when_one_branch_fails
    schema = {
      "allOf" => [
        { "type" => "object" },
        { "required" => ["a"] }
      ]
    }
    errors = V.validate(schema, { "b" => 1 })
    assert_equal 1, errors.size
    assert_match(/missing required property "a"/, errors.first[:message])
  end

  # --- $ref ----------------------------------------------------------

  def test_ref_resolves_against_root_definitions
    schema = {
      "definitions" => {
        "Color" => { "type" => "string", "enum" => ["red", "green"] }
      },
      "type" => "object",
      "properties" => { "c" => { "$ref" => "#/definitions/Color" } }
    }
    assert_empty V.validate(schema, { "c" => "red" })
    refute_empty V.validate(schema, { "c" => "blue" })
  end

  def test_ref_to_unknown_definition_raises
    schema = { "$ref" => "#/definitions/Missing", "definitions" => {} }
    err = assert_raises(RuntimeError) { V.validate(schema, "anything") }
    assert_match(/unknown \$ref target/, err.message)
  end

  def test_ref_remote_form_raises
    schema = { "$ref" => "https://example.com/foo.json", "definitions" => {} }
    err = assert_raises(RuntimeError) { V.validate(schema, "anything") }
    assert_match(/only #\/definitions\//, err.message)
  end

  # --- unknown keywords are ignored ---------------------------------

  def test_unknown_keywords_are_ignored
    schema = {
      "type" => "string",
      "format" => "uri",
      "pattern" => "^https://",
      "minLength" => 10,
      "examples" => ["http://example.com"]
    }
    # `format`, `pattern`, `minLength`, `examples` are not enforced here.
    assert_empty V.validate(schema, "x")
  end

  # --- end-to-end: real Codex schemas -------------------------------

  def test_thread_start_params_accepts_empty_object
    schema = load_fixture("v2/ThreadStartParams.json")
    # Every property is optional in ThreadStartParams.
    assert_empty V.validate(schema, {})
  end

  def test_thread_start_params_rejects_wrong_type
    schema = load_fixture("v2/ThreadStartParams.json")
    errors = V.validate(schema, { "approvalPolicy" => 42 })
    refute_empty errors
    assert_includes errors.first[:path], "/approvalPolicy"
  end

  def test_command_execution_approval_response_accepts_correct_decision
    # CommandExecutionApprovalDecision enum is accept|acceptForSession|decline|cancel|...
    schema = load_fixture("CommandExecutionRequestApprovalResponse.json")
    assert_empty V.validate(schema, { "decision" => "accept" })
    assert_empty V.validate(schema, { "decision" => "decline" })
  end

  def test_command_execution_approval_response_rejects_review_decision_value
    # The Phase 5 bug: harnex sends `{decision: "approved"}` here, but
    # `"approved"` belongs to ReviewDecision (used by applyPatchApproval /
    # execCommandApproval), not CommandExecutionApprovalDecision. The
    # contract test must catch that.
    schema = load_fixture("CommandExecutionRequestApprovalResponse.json")
    errors = V.validate(schema, { "decision" => "approved" })
    refute_empty errors, "validator should reject 'approved' as a CommandExecutionApprovalDecision"
  end

  def test_apply_patch_approval_response_accepts_review_decision_approved
    # Sanity check that 'approved' IS a valid ReviewDecision — this proves
    # the Phase 5 bug is a confused-enum copy-paste, not a value harnex
    # invented from nothing.
    schema = load_fixture("ApplyPatchApprovalResponse.json")
    assert_empty V.validate(schema, { "decision" => "approved" })
  end
end
