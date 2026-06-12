# Draft-7 JSON Schema validator — vendored subset.
#
# Stdlib-only Ruby (project policy). Just enough Draft-7 to validate
# harnex's outgoing JSON-RPC payloads and `Fixtures::Codex` builder
# output against the captured `codex app-server generate-json-schema`
# fixtures under `test/fixtures/codex_schema/`.
#
# Supported keywords:
#
#   type           — single string or array-of-strings union
#   required       — array of property names
#   enum           — value must equal one of the listed literals
#   const          — value must equal the listed literal
#   minLength      — minimum string length
#   properties     — per-property sub-schemas
#   additionalProperties
#                  — false | true | <schema>
#   items          — homogeneous array element schema (Hash form only)
#   oneOf          — value must match exactly one of the listed schemas
#   anyOf          — value must match at least one
#   allOf          — value must match all
#   $ref           — local-only; "#/definitions/<name>" resolved against
#                    the root schema's `definitions` table
#
# Unknown keywords (description, title, default, format, pattern,
# minimum, maximum, examples, ...) are silently ignored, per the JSON
# Schema convention that unrecognised keywords are annotations. If
# validation gaps surface later, extend here rather than working around
# in test code.
#
# Returns `[]` when the instance is valid, or an Array of
# `{ path: "/foo/bar", message: "..." }` hashes otherwise. Path is the
# JSON Pointer to the offending node ("/" for the root).
module JsonSchemaValidator
  module_function

  def validate(schema, instance, root_schema: nil, path: "")
    root_schema ||= schema
    return [] if schema == true
    return [error(path, "schema is `false` (nothing validates)")] if schema == false
    return [] unless schema.is_a?(Hash)

    if schema["$ref"]
      resolved = resolve_ref(schema["$ref"], root_schema)
      return validate(resolved, instance, root_schema: root_schema, path: path)
    end

    errors = []
    errors.concat(check_type(schema["type"], instance, path)) if schema.key?("type")
    errors.concat(check_enum(schema["enum"], instance, path)) if schema.key?("enum")
    errors.concat(check_const(schema["const"], instance, path)) if schema.key?("const")
    errors.concat(check_min_length(schema["minLength"], instance, path)) if schema.key?("minLength")
    if instance.is_a?(Hash)
      errors.concat(check_required(schema["required"], instance, path)) if schema.key?("required")
      if schema.key?("properties") || schema.key?("additionalProperties")
        errors.concat(check_object(schema, instance, root_schema, path))
      end
    end
    errors.concat(check_items(schema["items"], instance, root_schema, path)) if schema.key?("items") && instance.is_a?(Array)
    errors.concat(check_one_of(schema["oneOf"], instance, root_schema, path)) if schema.key?("oneOf")
    errors.concat(check_any_of(schema["anyOf"], instance, root_schema, path)) if schema.key?("anyOf")
    errors.concat(check_all_of(schema["allOf"], instance, root_schema, path)) if schema.key?("allOf")
    errors
  end

  TYPE_CHECKERS = {
    "string"  => ->(v) { v.is_a?(String) },
    "number"  => ->(v) { v.is_a?(Numeric) && !v.is_a?(TrueClass) && !v.is_a?(FalseClass) },
    "integer" => ->(v) { v.is_a?(Integer) || (v.is_a?(Float) && v.finite? && v == v.to_i) },
    "boolean" => ->(v) { v == true || v == false },
    "array"   => ->(v) { v.is_a?(Array) },
    "object"  => ->(v) { v.is_a?(Hash) },
    "null"    => ->(v) { v.nil? }
  }.freeze

  def check_type(type, instance, path)
    types = type.is_a?(Array) ? type : [type]
    return [] if types.any? { |t| TYPE_CHECKERS[t]&.call(instance) }
    [error(path, "expected type #{type.inspect}, got #{describe(instance)}")]
  end

  def check_enum(values, instance, path)
    return [] if values.include?(instance)
    [error(path, "value #{describe(instance)} is not in enum #{values.inspect}")]
  end

  def check_const(value, instance, path)
    return [] if instance == value
    [error(path, "value #{describe(instance)} does not equal const #{value.inspect}")]
  end

  def check_min_length(min_length, instance, path)
    return [] unless instance.is_a?(String)
    return [] if instance.length >= min_length.to_i

    [error(path, "string length #{instance.length} is less than minLength #{min_length}")]
  end

  def check_required(keys, instance, path)
    keys.reject { |k| instance.key?(k) }.map do |k|
      error(path, "missing required property #{k.inspect}")
    end
  end

  def check_object(schema, instance, root_schema, path)
    errors = []
    properties = schema["properties"] || {}
    properties.each do |key, sub_schema|
      next unless instance.key?(key)
      errors.concat(validate(sub_schema, instance[key], root_schema: root_schema, path: "#{path}/#{key}"))
    end
    return errors unless schema.key?("additionalProperties")

    additional = schema["additionalProperties"]
    extras = instance.keys - properties.keys
    case additional
    when false
      extras.each do |key|
        errors << error(path, "additional property #{key.inspect} is not allowed")
      end
    when true, nil
      # any allowed
    when Hash
      extras.each do |key|
        errors.concat(validate(additional, instance[key], root_schema: root_schema, path: "#{path}/#{key}"))
      end
    end
    errors
  end

  def check_items(items, instance, root_schema, path)
    return [] unless items.is_a?(Hash) || items == true || items == false
    errors = []
    instance.each_with_index do |elem, idx|
      errors.concat(validate(items, elem, root_schema: root_schema, path: "#{path}/#{idx}"))
    end
    errors
  end

  def check_one_of(schemas, instance, root_schema, path)
    matches = schemas.count { |s| validate(s, instance, root_schema: root_schema, path: path).empty? }
    return [] if matches == 1
    if matches == 0
      [error(path, "value did not match any of the #{schemas.size} oneOf schemas")]
    else
      [error(path, "value matched #{matches} of the #{schemas.size} oneOf schemas (expected exactly 1)")]
    end
  end

  def check_any_of(schemas, instance, root_schema, path)
    return [] if schemas.any? { |s| validate(s, instance, root_schema: root_schema, path: path).empty? }
    [error(path, "value did not match any of the #{schemas.size} anyOf schemas")]
  end

  def check_all_of(schemas, instance, root_schema, path)
    schemas.flat_map { |s| validate(s, instance, root_schema: root_schema, path: path) }
  end

  def resolve_ref(ref, root)
    unless ref.is_a?(String) && ref.start_with?("#/definitions/")
      raise "JsonSchemaValidator: only #/definitions/<name> $refs are supported (got #{ref.inspect})"
    end
    name = ref.sub("#/definitions/", "")
    definitions = root.is_a?(Hash) ? (root["definitions"] || {}) : {}
    unless definitions.key?(name)
      raise "JsonSchemaValidator: unknown $ref target #{ref.inspect}"
    end
    definitions[name]
  end

  def error(path, message)
    { path: path.empty? ? "/" : path, message: message }
  end

  def describe(value)
    case value
    when nil then "null"
    when String then "string #{value.inspect}"
    when Integer then "integer #{value}"
    when Float then "number #{value}"
    when true, false then "boolean #{value}"
    when Array then "array (#{value.size} items)"
    when Hash then "object (#{value.size} keys)"
    else value.class.name
    end
  end
end
