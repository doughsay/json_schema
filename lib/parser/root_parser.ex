defmodule JsonSchema.Parser.RootParser do
  @moduledoc """
  Contains logic for verifying the schema version of a JSON schema file.
  """

  require Logger

  alias JsonSchema.{Parser, Types}

  alias Parser.{
    AllOfParser,
    AnyOfParser,
    ArrayParser,
    DefinitionsParser,
    ErrorUtil,
    ObjectParser,
    OneOfParser,
    ParserError,
    ParserResult,
    SchemaResult,
    TupleParser,
    TypeReferenceParser,
    Util
  }

  alias Types.SchemaDefinition

  @spec parse_schema(Types.schemaNode(), Path.t()) :: SchemaResult.t()
  def parse_schema(root_node, schema_file_path) do
    with {:ok, _schema_version} <- parse_schema_version(root_node),
         {:ok, schema_id} <- parse_schema_id(root_node) do
      title = Map.get(root_node, "title", "Root")
      description = Map.get(root_node, "description")

      root_node_no_def = Map.delete(root_node, "definitions")

      root_node_only_def =
        Map.take(root_node, [
          "$schema",
          "id",
          "title",
          "definitions"
        ])

      root_parser_result = parse_root_object(root_node_no_def, schema_id, title)

      definitions_parser_result = parse_definitions(root_node_only_def, schema_id)

      %ParserResult{type_dict: type_dict, errors: errors, warnings: warnings} =
        ParserResult.merge(root_parser_result, definitions_parser_result)

      schema_dict = %{
        to_string(schema_id) => %SchemaDefinition{
          file_path: schema_file_path,
          id: schema_id,
          title: title,
          description: description,
          types: type_dict
        }
      }

      schema_errors =
        if length(errors) > 0 do
          [{schema_file_path, errors}]
        else
          []
        end

      schema_warnings =
        if length(warnings) > 0 do
          [{schema_file_path, warnings}]
        else
          []
        end

      SchemaResult.new(schema_dict, schema_warnings, schema_errors)
    else
      {:error, error} ->
        schema_warnings = [{schema_file_path, []}]
        schema_errors = [{schema_file_path, [error]}]
        SchemaResult.new(%{}, schema_warnings, schema_errors)
    end
  end

  @spec parse_definitions(Types.schemaNode(), URI.t()) :: ParserResult.t()
  defp parse_definitions(schema_root_node, schema_id) do
    if DefinitionsParser.type?(schema_root_node) do
      DefinitionsParser.parse(
        schema_root_node,
        schema_id,
        nil,
        URI.parse("#"),
        ""
      )
    else
      ParserResult.new(%{})
    end
  end

  @spec parse_root_object(map, URI.t(), String.t()) :: ParserResult.t()
  defp parse_root_object(schema_root_node, schema_id, name) do
    type_path = URI.parse("#")

    cond do
      AllOfParser.type?(schema_root_node) ->
        schema_root_node
        |> AllOfParser.parse(schema_id, schema_id, type_path, name)

      AnyOfParser.type?(schema_root_node) ->
        schema_root_node
        |> AnyOfParser.parse(schema_id, schema_id, type_path, name)

      ArrayParser.type?(schema_root_node) ->
        schema_root_node
        |> ArrayParser.parse(schema_id, schema_id, type_path, name)

      ObjectParser.type?(schema_root_node) ->
        schema_root_node
        |> ObjectParser.parse(schema_id, schema_id, type_path, name)

      OneOfParser.type?(schema_root_node) ->
        schema_root_node
        |> OneOfParser.parse(schema_id, schema_id, type_path, name)

      TupleParser.type?(schema_root_node) ->
        schema_root_node
        |> TupleParser.parse(schema_id, schema_id, type_path, name)

      TypeReferenceParser.type?(schema_root_node) ->
        schema_root_node
        |> TypeReferenceParser.parse(schema_id, schema_id, type_path, name)

      true ->
        ParserResult.new()
    end
  end

  @supported_versions [
    "http://json-schema.org/draft-04/schema#",
    "http://json-schema.org/draft-07/schema#"
  ]

  @doc """
  Returns `:ok` if the given JSON schema has a known supported version,
  and an error tuple otherwise.

  ## Examples

      iex> schema = %{"$schema" => "http://json-schema.org/draft-07/schema#"}
      iex> parse_schema_version(schema)
      {:ok, "http://json-schema.org/draft-07/schema#"}

      iex> schema = %{"$schema" => "http://example.org/my-own-schema"}
      iex> {:error, error} = parse_schema_version(schema)
      iex> error.error_type
      :unsupported_schema_version

      iex> {:error, error} = parse_schema_version(%{})
      iex> error.error_type
      :missing_property

  """
  @spec parse_schema_version(Types.schemaNode()) ::
          {:ok, String.t()} | {:error, ParserError.t()}
  def parse_schema_version(%{"$schema" => schema_str})
      when is_binary(schema_str) do
    schema_version = schema_str |> URI.parse() |> to_string

    if schema_version in @supported_versions do
      {:ok, schema_version}
    else
      {:error, ErrorUtil.unsupported_schema_version(schema_str, @supported_versions)}
    end
  end

  def parse_schema_version(%{"$schema" => schema}) do
    schema_type = Util.get_type(schema)
    {:error, ErrorUtil.invalid_type("#", "$schema", "string", schema_type)}
  end

  def parse_schema_version(_schema) do
    path = URI.parse("#")
    {:error, ErrorUtil.missing_property(path, "$schema")}
  end

  @valid_uri_schemes ["http", "https", "urn"]

  @doc """
  Parses the ID of a JSON schema.

  ## Examples

      iex> parse_schema_id(%{"id" => "http://www.example.com/my-schema"})
      {:ok, URI.parse("http://www.example.com/my-schema")}

      iex> parse_schema_id(%{"$id" => "http://www.example.com/my-schema"})
      {:ok, URI.parse("http://www.example.com/my-schema")}

      iex> {:error, error} = parse_schema_id(%{"id" => "foo bar baz"})
      iex> error.error_type
      :invalid_uri

      iex> {:error, error} = parse_schema_id(%{})
      iex> error.error_type
      :missing_property

  """
  @spec parse_schema_id(Types.schemaNode()) ::
          {:ok, URI.t()} | {:error, ParserError.t()}
  def parse_schema_id(%{"$id" => schema_id}) when is_binary(schema_id) do
    do_parse_schema_id(schema_id)
  end

  def parse_schema_id(%{"id" => schema_id}) when is_binary(schema_id) do
    do_parse_schema_id(schema_id)
  end

  def parse_schema_id(%{"$id" => schema_id}) do
    {:error, ErrorUtil.invalid_type("#", "id", "string", schema_id)}
  end

  def parse_schema_id(%{"id" => schema_id}) do
    {:error, ErrorUtil.invalid_type("#", "id", "string", schema_id)}
  end

  def parse_schema_id(_schema_node) do
    {:error, ErrorUtil.missing_property("#", "id")}
  end

  @spec do_parse_schema_id(String.t()) ::
          {:ok, URI.t()} | {:error, ParserError.t()}
  defp do_parse_schema_id(schema_id) do
    parsed_id = schema_id |> URI.parse()

    if parsed_id.scheme in @valid_uri_schemes do
      {:ok, parsed_id}
    else
      {:error, ErrorUtil.invalid_uri("#", "id", schema_id)}
    end
  end
end
