defmodule Mix.Noap.GenCode.WSDLWrap do
  defstruct [
    :endpoint,
    :module_prefix,
    :namespace_map,
    :schema_map,
    :operations,
    :message_map
  ]

  # @soap_version_namespaces %{
  #   "1.1" => "http://schemas.xmlsoap.org/wsdl/soap/",
  #   "1.2" => "http://schemas.xmlsoap.org/wsdl/soap12/"
  # }

  import Meeseeks.XPath

  alias __MODULE__.{OperationWrap, Util}

  @wsdl_namespace "http://schemas.xmlsoap.org/wsdl/"
  @soap_namespace "http://schemas.xmlsoap.org/wsdl/soap/"
  @schema_namespace "http://www.w3.org/2001/XMLSchema"

  def new(wsdl_path, module_prefix, options \\ []) do
    module_prefix = Util.module_to_string(module_prefix)
    str = File.read!(wsdl_path)
    doc = Meeseeks.parse(str, :xml)
    schema_ns = Noap.XMLUtil.find_namespace(doc, "http://www.w3.org/2001/XMLSchema")
    endpoint = get_endpoint(doc)
    namespace_map = get_namespace_map(doc)
    schema_map = get_schema_map(doc, schema_ns, module_prefix, namespace_map, options)
    message_map = get_message_map(doc)
    operations = get_operations(doc, schema_map, message_map, options)

    %__MODULE__{
      endpoint: endpoint,
      module_prefix: module_prefix,
      namespace_map: namespace_map,
      schema_map: schema_map,
      operations: operations,
      message_map: message_map
    }
  end

  defp find_complex_type(schema_map, message_map, message_name) do
    message = message_map[message_name]

    if is_nil(message) do
      raise "Could not find message matching #{message_name} for operation"
    end

    schema = schema_map[message.ns]

    if is_nil(schema) do
      raise "Could not find schema for message=#{inspect(message)}"
    end

    action = schema.top_types[message.name]

    if is_nil(action) do
      raise "Couldn't find action for #{message.name} #{inspect(schema)}"
    end

    type = schema.complex_type_map[action.name]

    if is_nil(type) do
      raise "Couldn't find type for #{action.name} #{inspect(schema)}"
    end

    {schema, type}
  end

  defp get_namespace_map(doc) do
    # Meeseeks doesn't support namespace axis directly
    # We'll extract namespaces by checking the root element's xmlns attributes
    root = Meeseeks.one(doc, xpath("/*"))

    case root do
      nil -> %{}
      element -> extract_namespaces_from_element(element, %{})
    end
  end

  defp extract_namespaces_from_element(element, acc) do
    # Check default namespace
    acc =
      case Meeseeks.attr(element, "xmlns") do
        nil -> acc
        value -> Map.put(acc, "", value)
      end

    # Check common prefixes
    common_prefixes = ["soap", "wsdl", "xsd", "xs", "tns", "s", "body", "ns0", "ns1", "ns2", "ns3", "ns4"]
    Enum.reduce(common_prefixes, acc, fn prefix, acc ->
      case Meeseeks.attr(element, "xmlns:#{prefix}") do
        nil -> acc
        value -> Map.put(acc, prefix, value)
      end
    end)
  end

  defp get_schema_map(doc, schema_ns, module_prefix, namespace_map, options) do
    doc
    |> Meeseeks.all(
      xpath("//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='types']/*[namespace-uri()='#{@schema_namespace}' and local-name()='schema']")
    )
    |> Enum.into(
      %{},
      fn schema_node ->
        schema =
          __MODULE__.SchemaWrap.new(
            schema_ns,
            module_prefix,
            schema_node,
            namespace_map,
            options
          )

        {schema.target_ns, schema}
      end
    )
  end

  @spec get_endpoint(Meeseeks.Document.t()) :: String.t()
  defp get_endpoint(doc) do
    address_node =
      doc
      |> Meeseeks.one(
        xpath("//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='service']/*[namespace-uri()='#{@wsdl_namespace}' and local-name()='port']/*[namespace-uri()='#{@soap_namespace}' and local-name()='address']")
      )

    case address_node do
      nil -> ""
      node -> Meeseeks.attr(node, "location") || ""
    end
  end

  defp get_operations(doc, schema_map, message_map, _opts) do
    port_type_node = Meeseeks.one(doc, xpath("//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='portType']"))
    port_type_name =
      case port_type_node do
        nil -> ""
        node -> Meeseeks.attr(node, "name") || ""
      end

    binding_node =
      if port_type_name != "" do
        Meeseeks.one(
          doc,
          xpath("//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='binding' and @name='#{port_type_name}']")
        )
      else
        nil
      end || Meeseeks.one(doc, xpath("//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='binding']"))

    port_type_node
    |> case do
      nil -> []
      node ->
        Meeseeks.all(node, xpath(".//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='operation']"))
        |> Enum.map(&build_operation(binding_node, &1, schema_map, message_map))
    end
  end

  defp build_operation(binding_node, op_node, schema_map, message_map) do
    name = Meeseeks.attr(op_node, "name") || ""
    soap_action = get_soap_action(binding_node, name) || ""
    input_message_name = get_operation_arg_name(op_node, "input", "message")
    output_message_name = get_operation_arg_name(op_node, "output", "message")
    input_name = message_map[input_message_name][:name]
    output_name = message_map[output_message_name][:name]
    input_header = get_operation_input_header(op_node)

    {input_schema, input_complex_type} =
      find_complex_type(schema_map, message_map, input_message_name)

    {output_schema, output_complex_type} =
      find_complex_type(schema_map, message_map, output_message_name)

    action = input_schema.top_types[name]

    if is_nil(action) do
      raise "Could not find action for operation=#{name}"
    end

    %OperationWrap{
      name: name,
      underscored_name: Util.underscore(name),
      input_name: input_name,
      input_schema: input_schema,
      input_complex_type: input_complex_type,
      output_name: output_name,
      output_schema: output_schema,
      output_complex_type: output_complex_type,
      soap_action: soap_action,
      input_header_message: input_header[:message],
      input_header_part: input_header[:part],
      action_attribute: action.attribute,
      action_tag: action.tag
    }
  end

  defp get_soap_action(nil, _name), do: nil

  defp get_soap_action(binding_node, name) do
    operation_node =
      Meeseeks.one(
        binding_node,
        xpath(".//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='operation' and @name='#{name}']")
      )

    case operation_node do
      nil -> nil
      node ->
        soap_op = Meeseeks.one(node, xpath(".//*[namespace-uri()='#{@soap_namespace}' and local-name()='operation']"))
        case soap_op do
          nil -> nil
          soap_node -> Meeseeks.attr(soap_node, "soapAction") || nil
        end
    end
  end

  defp get_operation_arg_name(op_node, element_name, attr_name) do
    input_node = Meeseeks.one(op_node, xpath(".//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='#{element_name}']"))
    case input_node do
      nil -> ""
      node ->
        attr_value = Meeseeks.attr(node, attr_name) || ""
        String.split(attr_value, ":", parts: 2)
        |> Enum.at(1) || ""
    end
  end

  defp get_operation_input_header(op_node) do
    input_node = Meeseeks.one(op_node, xpath(".//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='input']"))
    case input_node do
      nil -> %{}
      node ->
        header_node = Meeseeks.one(node, xpath(".//*[namespace-uri()='#{@soap_namespace}' and local-name()='header']"))
        get_operation_input_header_message_part(header_node)
    end
  end

  defp get_operation_input_header_message_part(nil), do: %{}

  defp get_operation_input_header_message_part(header_node) do
    %{
      message: Meeseeks.attr(header_node, "message") || "",
      part: Meeseeks.attr(header_node, "part") || ""
    }
  end

  defp get_message_map(doc) do
    doc
    |> Meeseeks.all(xpath("//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='message']"))
    |> Enum.reduce(
      %{},
      fn node, map ->
        name = Meeseeks.attr(node, "name") || ""
        Map.put(map, name, get_message_part(node))
      end
    )
  end

  defp get_message_part(element) do
    part_node = Meeseeks.one(element, xpath(".//*[namespace-uri()='#{@wsdl_namespace}' and local-name()='part']"))
    element_attr =
      case part_node do
        nil -> ""
        node -> Meeseeks.attr(node, "element") || ""
      end

    [ns, name] = String.split(element_attr, ":", parts: 2)
    %{ns: String.to_atom(ns || ""), name: name || ""}
  end
end
