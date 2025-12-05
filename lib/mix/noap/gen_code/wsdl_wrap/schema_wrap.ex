defmodule Mix.Noap.GenCode.WSDLWrap.SchemaWrap do
  require Logger

  defstruct [
    :schema_ns,
    :target_namespace,
    :element_form_default,
    :target_ns,
    :module,
    :top_types,
    :complex_type_map
  ]

  @type_to_simple_map %{
    "boolean" => :boolean,
    "date" => :date,
    "dateTime" => :datetime,
    "double" => :float,
    "float" => :float,
    "int" => :integer,
    "integer" => :integer,
    "long" => :integer,
    "string" => :string
  }

  alias Mix.Noap.GenCode.WSDLWrap.{Action, ComplexType, Field, Options, Util}
  import Meeseeks.XPath

  @schema_namespace "http://www.w3.org/2001/XMLSchema"

  def new(schema_ns, parent_module, schema_element, namespace_map, options) do
    target_namespace = Meeseeks.attr(schema_element, "targetNamespace") || ""
    element_form_default = Meeseeks.attr(schema_element, "elementFormDefault") || ""

    if target_namespace == "" do
      raise "Not sure how to handle with no targetNamespace: #{inspect(schema_element)}"
    end

    target_ns = Noap.XMLUtil.find_namespace(schema_element, target_namespace) |> String.to_atom()

    module =
      Options.schema_module(options, target_ns) ||
        Util.convert_url_to_module(target_namespace, parent_module)

    top_type_elements =
      schema_element
      |> Meeseeks.all(xpath(".//*[namespace-uri()='#{@schema_namespace}' and local-name()='element']"))

    # Fallback: if namespace-uri() didn't work, try simple query
    top_type_elements = if Enum.empty?(top_type_elements) do
      schema_element
      |> Meeseeks.all(xpath(".//element"))
    else
      top_type_elements
    end

      top_types =
      top_type_elements
      |> Enum.into(
        %{},
        fn element ->
          name = Meeseeks.attr(element, "name") || ""
          action_with_namespace = Meeseeks.attr(element, "type") || ""
          {name, Action.new(name, action_with_namespace, namespace_map)}
        end
      )

    schema = %__MODULE__{
      schema_ns: schema_ns,
      # element: schema_element,
      target_namespace: target_namespace,
      target_ns: target_ns,
      element_form_default: element_form_default,
      module: module,
      top_types: top_types,
      complex_type_map: nil
    }

    complex_type_elements = schema_element
    |> Meeseeks.all(xpath(".//*[namespace-uri()='#{@schema_namespace}' and local-name()='complexType']"))

    # Fallback: if namespace-uri() didn't work, try simple query
    complex_type_elements = if Enum.empty?(complex_type_elements) do
      schema_element
      |> Meeseeks.all(xpath(".//complexType"))
    else
      complex_type_elements
    end

    complex_type_map =
      complex_type_elements
      |> Enum.filter(fn element ->
        # Skip complexTypes without names (inline types)
        name = Meeseeks.attr(element, "name")
        name != nil && name != ""
      end)
      |> Enum.map(&parse_complex_type(schema, &1, nil))
      |> Enum.into(%{}, &{&1.name, &1})

    schema = %{schema | complex_type_map: complex_type_map}

    complex_type_map =
      top_type_elements
      |> Enum.map(&parse_type(schema, &1, nil))
      |> Enum.reduce(complex_type_map, &add_to_complex_type_map/2)

    complex_type_map =
      complex_type_map
      |> Enum.map(fn {name, complex_type} ->
        {name, convert_name_to_complex_type(complex_type_map, complex_type)}
      end)
      |> Enum.into(%{})

    %{schema | complex_type_map: complex_type_map}
  end

  defp convert_name_to_complex_type(complex_type_map, complex_type = %ComplexType{}) do
    fields =
      complex_type.fields
      |> Enum.map(fn field ->
        %{field | type: convert_name_to_complex_type(complex_type_map, field.type)}
      end)

    %{complex_type | fields: fields}
  end

  defp convert_name_to_complex_type(_complex_type_map, simple_type) when is_atom(simple_type) do
    simple_type
  end

  defp convert_name_to_complex_type(complex_type_map, type_name)
       when is_binary(type_name) do
    # Check if it's a simple type name that should be converted to atom
    simple_type = @type_to_simple_map[type_name]
    if simple_type do
      simple_type
    else
      # It's a complex type name
      complex_type_map[type_name] ||
        raise "Couldn't find complex type of #{type_name}"
    end
  end

  defp add_to_complex_type_map(complex_type = %ComplexType{}, map) do
    Map.put(map, complex_type.name, complex_type)
  end

  defp add_to_complex_type_map(complex_type_name, map) when is_binary(complex_type_name) do
    # Should already exist or will be created later
    map
  end

  defp parse_complex_type(schema, parent_element, parent_complex_type) do
    name = Meeseeks.attr(parent_element, "name") || ""

    if name == "" do
      raise "Not sure how to handle complex_type without name #{inspect(parent_element)}"
    end

    elements = Meeseeks.all(
      parent_element,
      xpath(".//*[namespace-uri()='#{@schema_namespace}' and local-name()='sequence']/*[namespace-uri()='#{@schema_namespace}' and local-name()='element']")
    )

    # Fallback: if namespace-uri() didn't work, try simple query
    elements = if Enum.empty?(elements) do
      Meeseeks.all(parent_element, xpath(".//sequence//element"))
    else
      elements
    end
    parse_complex_type(schema, name, elements, parent_complex_type)
  end

  defp parse_complex_type(schema, name, elements, parent_complex_type) do
    Logger.debug("Creating complex type name=#{name}")

    Enum.reduce(
      elements,
      ComplexType.new(schema.module, name, parent_complex_type),
      fn element, complex_type ->
        field = parse_field(schema, element, complex_type)
        ComplexType.add_field(complex_type, field)
      end
    )
    # The fields are in reverse order based on add_field so put them back in correct order
    |> (fn complex_type -> %{complex_type | fields: Enum.reverse(complex_type.fields)} end).()
  end

  defp parse_field(schema, element, parent_complex_type) do
    xml_name = Meeseeks.attr(element, "name") || ""

    if xml_name == "" do
      raise "Not sure how to parse type without name #{inspect(element)}"
    end

    xml_type = Meeseeks.attr(element, "type") || ""

    case xml_type do
      "" ->
        field_type = parse_type(schema, element, parent_complex_type)

        embeds =
          cond do
            is_atom(field_type) ->
              :field

            true ->
              max_occurs = Meeseeks.attr(element, "maxOccurs") || ""
              Util.max_occurs_embed(max_occurs)
          end

        Field.new(embeds, xml_name, field_type)

      xml_type ->
        {field_or_embeds, type} = convert_type(schema, element, xml_type)
        Field.new(field_or_embeds, xml_name, type)
    end
  end

  defp convert_type(schema, element, xml_type) do
    case String.split(xml_type, ":", parts: 2) do
      [simple_type] ->
        type = @type_to_simple_map[simple_type]

        if is_nil(type) do
          raise("Not sure how to handle type=#{xml_type}")
        end

        {:field, type}

      [namespace, name] ->
        cond do
          namespace == schema.schema_ns ->
            convert_type(schema, element, name)

          true ->
            max_occurs = Meeseeks.attr(element, "maxOccurs") || ""
            embeds = Util.max_occurs_embed(max_occurs)
            {embeds, name}
        end
    end
  end

  defp parse_type(schema, parent_element, parent_complex_type) do
    name = Meeseeks.attr(parent_element, "name") || ""

    type = Meeseeks.attr(parent_element, "type") || ""

    cond do
      type != "" ->
        {_field_or_embeds, ctype} = convert_type(schema, parent_element, type)
        ctype

      (complex_elements = get_complex_type_elements(parent_element)) != [] ->
        parse_complex_type(schema, name, complex_elements, parent_complex_type)

      (simple_type_restriction = get_simple_type_restriction_element(parent_element)) != nil ->
        base_type = Meeseeks.attr(simple_type_restriction, "base") || ""

        if base_type == "" do
          raise(
            "Not sure how to handle name=#{name} simple_type_restriction " <>
              inspect(simple_type_restriction)
          )
        end

        {_field_or_embeds, ctype} = convert_type(schema, parent_element, base_type)
        ctype

      true ->
        # Empty field list is the only other possibility?
        parse_complex_type(schema, name, [], parent_complex_type)
    end
  end

  defp get_complex_type_elements(parent_element) do
    elements = parent_element
    |> Meeseeks.all(
      xpath(".//*[namespace-uri()='#{@schema_namespace}' and local-name()='complexType']/*[namespace-uri()='#{@schema_namespace}' and local-name()='sequence']/*[namespace-uri()='#{@schema_namespace}' and local-name()='element']")
    )

    # Fallback: if namespace-uri() didn't work, try simple query
    if Enum.empty?(elements) do
      parent_element
      |> Meeseeks.all(xpath(".//complexType//sequence//element"))
    else
      elements
    end
  end

  defp get_simple_type_restriction_element(parent_element) do
    element = parent_element
    |> Meeseeks.one(
      xpath(".//*[namespace-uri()='#{@schema_namespace}' and local-name()='simpleType']/*[namespace-uri()='#{@schema_namespace}' and local-name()='restriction']")
    )

    # Fallback: if namespace-uri() didn't work, try simple query
    if is_nil(element) do
      parent_element
      |> Meeseeks.one(xpath(".//simpleType//restriction"))
    else
      element
    end
  end
end
