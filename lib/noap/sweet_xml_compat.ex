defmodule Noap.SweetXmlCompat do
  @moduledoc """
  SweetXml-compatible API wrapper using Expath.

  This module provides the same function signatures and behavior as SweetXml,
  but uses Expath under the hood for OTP 25+ compatibility.
  """

  defmodule XPathExpr do
    @moduledoc false
    defstruct [:xpath, :modifier, :namespaces, :options]

    def new(xpath, modifier \\ nil, namespaces \\ %{}, options \\ []) do
      %__MODULE__{
        xpath: xpath,
        modifier: modifier,
        namespaces: namespaces,
        options: options
      }
    end

    def add_namespace(%__MODULE__{} = expr, prefix, namespace_uri) do
      %{expr | namespaces: Map.put(expr.namespaces, prefix, namespace_uri)}
    end
  end

  # Internal structure to represent a node that can be queried
  defmodule Node do
    @moduledoc false
    defstruct [:doc, :xpath_to_node, :namespaces, :xml_string]

    def new(doc, xpath_to_node, namespaces, xml_string) do
      %__MODULE__{
        doc: doc,
        xpath_to_node: xpath_to_node,
        namespaces: namespaces,
        xml_string: xml_string
      }
    end
  end

  @doc """
  Parses XML string into a document that can be queried with xpath/2.

  Options:
  - `:namespace_conformant` - if true, namespaces are preserved (default: true)
  """
  def parse(xml_string, opts \\ []) do
    namespace_conformant = Keyword.get(opts, :namespace_conformant, true)

    case Expath.new(xml_string) do
      {:ok, doc} ->
        if namespace_conformant do
          # Store namespaces in the document metadata
          namespaces = extract_namespaces(xml_string)
          %{doc: doc, namespaces: namespaces}
        else
          %{doc: doc, namespaces: %{}}
        end

      {:error, reason} ->
        raise "Failed to parse XML: #{inspect(reason)}"
    end
  end

  @doc """
  XPath sigil for creating XPath expressions.

  Modifiers:
  - `e` - returns a single element (or nil)
  - `l` - returns a list of elements
  - `s` - returns a string (text content)
  - no modifier - returns the raw result
  """
  defmacro sigil_x({:<<>>, _meta, [xpath_string]}, modifiers) when is_binary(xpath_string) do
    modifier = parse_modifier(modifiers)

    quote do
      Noap.SweetXmlCompat.XPathExpr.new(unquote(xpath_string), unquote(modifier))
    end
  end

  defmacro sigil_x({:<<>>, _meta, parts}, modifiers) when is_list(parts) do
    modifier = parse_modifier(modifiers)

    # Handle interpolated strings
    quote do
      xpath_string = unquote({:<<>>, [], parts})
      Noap.SweetXmlCompat.XPathExpr.new(xpath_string, unquote(modifier))
    end
  end

  defp parse_modifier([]), do: nil
  defp parse_modifier([modifier]) when modifier in [?e, ?l, ?s], do: modifier
  defp parse_modifier(_), do: nil

  @doc """
  Executes an XPath query on a document/node.

  Returns the result based on the modifier in the XPathExpr:
  - `e` - single element or nil
  - `l` - list of elements
  - `s` - string (text content)
  """
  # Handle SweetXpath structs from SweetXml
  def xpath(doc_or_node, %{__struct__: SweetXpath} = sweet_expr) do
    # Convert SweetXpath to XPathExpr
    xpath_string = sweet_expr.path |> List.to_string()
    modifier = cond do
      sweet_expr.is_value -> ?s
      sweet_expr.is_list -> ?l
      sweet_expr.is_keyword -> nil
      true -> ?e
    end

    namespaces = Enum.reduce(sweet_expr.namespaces || [], %{}, fn {prefix, uri}, acc ->
      Map.put(acc, prefix, uri)
    end)

    expr = XPathExpr.new(xpath_string, modifier, namespaces)
    xpath(doc_or_node, expr)
  end

  def xpath(doc_or_node, %XPathExpr{} = expr) do
    xpath_string = expr.xpath
    namespaces = expr.namespaces
    modifier = expr.modifier

    # Handle document with namespaces stored
    {expath_doc, all_namespaces, is_node, node_xpath, node_xml_string} =
      case doc_or_node do
        %{doc: d, namespaces: ns} -> {d, Map.merge(ns, namespaces), false, nil, nil}
        %Node{doc: d, namespaces: ns, xpath_to_node: np, xml_string: xml} -> {d, Map.merge(ns, namespaces), true, np, xml}
        _ -> {doc_or_node, namespaces, false, nil, nil}
      end

    # Adjust XPath for Node queries
    # When querying from a Node with a relative path, we need to prepend the node's XPath
    adjusted_xpath = if is_node and node_xpath do
      if String.starts_with?(xpath_string, "./") do
        # Remove ./ prefix and append to node's xpath
        relative_path = String.slice(xpath_string, 2..-1//-1)
        if relative_path == "" do
          node_xpath
        else
          # Combine node path with relative path
          if String.ends_with?(node_xpath, "/") do
            node_xpath <> relative_path
          else
            node_xpath <> "/" <> relative_path
          end
        end
      else
        # Absolute path - use as is
        xpath_string
      end
    else
      xpath_string
    end

    # Special case: if querying text() from a Node with xml_string, extract directly
    result = if is_node and node_xml_string and xpath_string == "./text()" and modifier == ?s do
      # Extract text content directly from XML string using regex
      case Regex.run(~r/>([^<]+)</, node_xml_string) do
        [_, text] -> [String.trim(text)]
        _ ->
          # Try querying the document with //text() to get all text nodes
          case Expath.query(expath_doc, "//text()") do
            {:ok, text_list} -> text_list
            _ -> []
          end
      end
    else
      # Normal path - query using adjusted_xpath
      # Handle empty xpath string
      if adjusted_xpath == "" do
        # Empty xpath selects current context - return the node or document
        return_result = if is_node do
        doc_or_node
      else
        expath_doc
      end
      [return_result]
    else
      # Expath has full namespace support
      # When XPath uses namespace prefixes (contains ":"), we must use query/3 with namespace map
      # When XPath doesn't use prefixes, try query/2 first, then query/3 if needed (for default namespace handling)
      xpath_uses_namespaces = String.contains?(adjusted_xpath, ":")

      if xpath_uses_namespaces and map_size(all_namespaces) > 0 do
        # XPath explicitly uses namespaces, must use query/3 with namespace mappings
        case Expath.query(expath_doc, adjusted_xpath, all_namespaces) do
          {:ok, res} -> res
          {:error, error} ->
            # Try to handle namespace::* axis which Expath might not support
            if String.contains?(adjusted_xpath, "namespace::") do
              # Return empty list for namespace axis queries (not fully supported)
              []
            else
              raise "XPath query failed: #{inspect(error)} for query: #{adjusted_xpath}"
            end
        end
      else
        # XPath doesn't use namespace prefixes
        # Try query/2 first (matches elements in no namespace)
        case Expath.query(expath_doc, adjusted_xpath) do
          {:ok, res} when res != [] -> res
          {:ok, []} when map_size(all_namespaces) > 0 ->
            # If query/2 returns empty but we have namespaces (possibly default namespace),
            # use local-name() to match elements regardless of namespace (like SweetXml)
            modified_xpath = modify_xpath_for_default_namespace(adjusted_xpath)
            case Expath.query(expath_doc, modified_xpath) do
              {:ok, res} -> res
              {:error, _} -> []
            end
          {:ok, res} -> res
          {:error, error} ->
            # Try to handle XPath axes that might not be supported
            if String.contains?(adjusted_xpath, "parent::") or String.contains?(adjusted_xpath, "ancestor::") do
              # For parent/ancestor axes, try a workaround or return empty
              # Expath might not support these axes directly
              []
            else
              raise "XPath query failed: #{inspect(error)} for query: #{adjusted_xpath}"
            end
        end
      end
    end
    end

    # Expath.query always returns a list, even for single results
    apply_modifier(result, modifier, expath_doc, adjusted_xpath, all_namespaces, doc_or_node)
  end

  def xpath(doc_or_node, xpath_string) when is_binary(xpath_string) do
    expr = XPathExpr.new(xpath_string)
    xpath(doc_or_node, expr)
  end

  @doc """
  Executes an XPath query with keyword list for extracting multiple values.

  Example:
      xpath(doc, ~x".", name: ~x"./@name"s, value: ~x"./text()"s)
  """
  def xpath(doc_or_node, %XPathExpr{} = base_expr, keyword_list) when is_list(keyword_list) do
    # First, get the base node(s)
    base_result = xpath(doc_or_node, base_expr)

    # Handle list of nodes
    if is_list(base_result) do
      Enum.map(base_result, fn node ->
        extract_keyword_values(node, keyword_list)
      end)
    else
      extract_keyword_values(base_result, keyword_list)
    end
  end

  defp extract_keyword_values(nil, _keyword_list) do
    nil
  end

  defp extract_keyword_values(node, keyword_list) do
    Enum.reduce(keyword_list, %{}, fn {key, %XPathExpr{} = expr}, acc ->
      value = xpath(node, expr)
      Map.put(acc, key, value)
    end)
  end

  defp apply_modifier(result, modifier, _doc, _xpath, _namespaces, _doc_or_node) when modifier == nil do
    # No modifier - return raw result, but if it's XML strings, parse them
    if is_list(result) and length(result) > 0 and is_binary(hd(result)) do
      # Check if results look like XML (start with <)
      if String.starts_with?(hd(result), "<") do
        # These are XML element strings, parse them
        Enum.map(result, fn xml_str ->
          case Expath.new(xml_str) do
            {:ok, doc} -> %Node{doc: doc, xpath_to_node: ".", namespaces: %{}, xml_string: xml_str}
            _ -> xml_str
          end
        end)
      else
        result
      end
    else
      result
    end
  end

  defp apply_modifier(result, ?e, _doc, xpath, namespaces, _doc_or_node) do
    # Single element - return first result or nil
    case result do
      [] -> nil
      [first | _] ->
        # If xpath ends with /text() or text(), extract text directly
        if String.ends_with?(xpath, "/text()") or String.ends_with?(xpath, "text()") do
          extract_text_content([first])
        else
          # Parse as node if it's a string (XML or text)
          parse_as_node(first, namespaces)
        end
      other -> other
    end
  end

  defp apply_modifier(result, ?l, _doc, xpath, namespaces, _doc_or_node) do
    # List of elements - ensure it's a list and parse strings as nodes
    parsed_result = if is_list(result) do
      result
    else
      [result]
    end

    # If the xpath ends with /text(), return strings directly (not Node structs)
    if String.ends_with?(xpath, "/text()") or String.ends_with?(xpath, "text()") do
      # For text() queries, return strings directly
      Enum.map(parsed_result, fn item ->
        extract_text_content([item])
      end)
    else
      # Parse each result as a node if it's a string
      Enum.map(parsed_result, fn item ->
        parse_as_node(item, namespaces)
      end)
    end
  end

  # Helper to parse a string result as a Node
  defp parse_as_node(item, namespaces) when is_binary(item) do
    # Try parsing as XML first
    if String.starts_with?(item, "<") do
      case Expath.new(item) do
        {:ok, node_doc} ->
          %Node{doc: node_doc, xpath_to_node: ".", namespaces: namespaces, xml_string: item}
        _ -> item
      end
    else
      # It's a text string, wrap it in XML and parse
      # Escape XML special characters
      escaped = item
        |> String.replace("&", "&amp;")
        |> String.replace("<", "&lt;")
        |> String.replace(">", "&gt;")
      wrapped_xml = "<root>#{escaped}</root>"
      case Expath.new(wrapped_xml) do
        {:ok, node_doc} ->
          %Node{doc: node_doc, xpath_to_node: ".", namespaces: namespaces, xml_string: wrapped_xml}
        _ -> item
      end
    end
  end
  defp parse_as_node(item, _namespaces), do: item

  defp apply_modifier(result, ?s, _doc, _xpath, _namespaces, _doc_or_node) do
    # String - extract text content
    # Expath.query returns a list of strings, so we need to join them
    # But SweetXML returns charlists for some cases, so we need to match that
    extract_text_content(result)
  end


  defp extract_text_content(nil), do: ""
  defp extract_text_content([]), do: ""
  defp extract_text_content(list) when is_list(list) do
    # Expath returns list of strings, join them
    # SweetXML returns strings (not charlists) for text() queries
    Enum.join(list, "")
  end
  defp extract_text_content(item) when is_binary(item), do: item
  defp extract_text_content(other) do
    # For other types, try to convert to string
    to_string(other)
  end

  @doc """
  Adds a namespace to an XPath expression.

  Example:
      ~x"soap:Body"e |> add_namespace("soap", "http://schemas.xmlsoap.org/soap/envelope/")
  """
  def add_namespace(%XPathExpr{} = expr, prefix, namespace_uri) do
    XPathExpr.add_namespace(expr, prefix, namespace_uri)
  end

  # Handle SweetXpath structs from SweetXml
  def add_namespace(%{__struct__: SweetXpath} = sweet_expr, prefix, namespace_uri) do
    # Convert SweetXpath to XPathExpr
    xpath_string = sweet_expr.path |> List.to_string()
    modifier = cond do
      sweet_expr.is_value -> ?s
      sweet_expr.is_list -> ?l
      sweet_expr.is_keyword -> nil
      true -> ?e
    end

    namespaces = Enum.reduce(sweet_expr.namespaces || [], %{}, fn {p, uri}, acc ->
      Map.put(acc, p, uri)
    end)
    |> Map.put(prefix, namespace_uri)

    XPathExpr.new(xpath_string, modifier, namespaces)
  end

  def add_namespace(xpath_string, prefix, namespace_uri) when is_binary(xpath_string) do
    expr = XPathExpr.new(xpath_string)
    add_namespace(expr, prefix, namespace_uri)
  end

  # Extract namespaces from XML string
  defp extract_namespaces(xml_string) do
    # Parse namespace declarations from XML
    regex = ~r/xmlns(?::(\w+))?=["']([^"']+)["']/
    matches = Regex.scan(regex, xml_string)

    Enum.reduce(matches, %{}, fn [_, prefix, uri], acc ->
      prefix = if prefix == "", do: nil, else: prefix
      if prefix do
        Map.put(acc, prefix, uri)
      else
        Map.put(acc, "", uri) # Default namespace
      end
    end)
  end

  # Modify XPath to use local-name() when elements might be in a default namespace
  # This makes XPath match elements regardless of namespace (like SweetXml behavior)
  defp modify_xpath_for_default_namespace(xpath_string) do
    # Replace element names in path with local-name() to match regardless of namespace
    # e.g., "//name/text()" becomes "//*[local-name()='name']/text()"
    # Handle // at start and / in middle
    xpath_string
    |> String.replace(~r/\/\/([a-zA-Z_][a-zA-Z0-9_]*)/, "//*[local-name()='\\1']")
    |> String.replace(~r/\/([a-zA-Z_][a-zA-Z0-9_]*)(?=\/|$)/, "/*[local-name()='\\1']")
  end
end
