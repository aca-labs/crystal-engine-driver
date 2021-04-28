require "json"

module PlaceOS
  # key => {class, required}
  SETTINGS_REQ = {} of Nil => Nil

  module Introspect
    def __generate_json_schema__
      {% begin %}
        {% properties = {} of Nil => Nil %}
        {% for ivar in @type.instance_vars %}
          {% ann = ivar.annotation(::JSON::Field) %}
          {% unless ann && (ann[:ignore] || ann[:ignore_deserialize]) %}
            {% properties[((ann && ann[:key]) || ivar).id] = ivar.type %}
          {% end %}
        {% end %}

        {% if properties.empty? %}
          { type: "object" }
        {% else %}
          {type: "object",  properties: {
            {% for key, ivar in properties %}
              {{key}}: PlaceOS.introspect({{ivar.resolve.name}}),
            {% end %}
          }, required: [
            {% for key, ivar in properties %}
              {% if !ivar.nilable? %}
                {{key.stringify}},
              {% end %}
            {% end %}
          ] of String}
        {% end %}
      {% end %}
    end
  end

  module ::JSON::Serializable
    macro included
      extend ::PlaceOS::Introspect
    end
  end

  macro introspect(klass)
    {% arg_name = klass.stringify %}
    {% if !arg_name.starts_with?("Union") && arg_name.includes?("|") %}
      PlaceOS.introspect(Union({{klass}}))
    {% else %}
      {% klass = klass.resolve %}
      {% klass_name = klass.name(generic_args: false) %}

      {% if klass <= Array %}
        has_items = PlaceOS.introspect {{klass.type_vars[0]}}
        if has_items.empty?
          {type: "array"}
        else
          {type: "array", items: has_items}
        end
      {% elsif klass.union? %}
        { anyOf: [
          {% for type in klass.union_types %}
            PlaceOS.introspect({{type}}),
          {% end %}
        ]}
      {% elsif klass_name.starts_with? "Tuple(" %}
        has_items = [
          {% for generic in klass.type_vars %}
            PlaceOS.introspect({{generic}}),
          {% end %}
        ]
        {type: "array", items: has_items}
      {% elsif klass_name.starts_with? "NamedTuple(" %}
        {type: "object",  properties: {
          {% for key in klass.keys %}
            {{key.id}}: PlaceOS.introspect({{klass[key].resolve.name}}),
          {% end %}
        }, required: [
          {% for key in klass.keys %}
            {% if !klass[key].resolve.nilable? %}
              {{key.id.stringify}},
            {% end %}
          {% end %}
        ] of String}
      {% elsif klass < Enum %}
        {type: "string",  enum: {{klass.constants.map(&.stringify)}} }
      {% elsif klass <= String %}
        { type: "string" }
      {% elsif klass <= Bool %}
        { type: "boolean" }
      {% elsif klass <= Int %}
        { type: "integer" }
      {% elsif klass <= Float %}
        { type: "number" }
      {% elsif klass <= Nil %}
        { type: "null" }
      {% elsif klass <= Hash %}
        { type: "object", additionalProperties: PlaceOS.introspect({{klass.type_vars[1]}}) }
      {% elsif klass.ancestors.includes? JSON::Serializable %}
        {{klass}}.__generate_json_schema__
      {% else %}
        # anything will validate (JSON::Any)
        {} of String => String
      {% end %}
    {% end %}
  end
end