///|
/// An OpenAI-compatible function tool schema.
struct ToolSchema {
  name : String
  description : String
  parameters : Json
}

///|
fn ToolSchema::to_json(self : ToolSchema) -> Json {
  Json::object({
    "type": Json::string("function"),
    "function": Json::object({
      "name": Json::string(self.name),
      "description": Json::string(self.description),
      "parameters": self.parameters,
    }),
  })
}

///|
fn string_field(description : String) -> Json {
  Json::object({
    "type": Json::string("string"),
    "description": Json::string(description),
  })
}

///|
fn object_schema(
  properties : Map[String, Json],
  required : Array[String],
) -> Json {
  Json::object({
    "type": Json::string("object"),
    "properties": Json::object(properties),
    "required": Json::array(required.map(Json::string)),
  })
}

///|
fn agent_tools() -> Array[ToolSchema] {
  [
    {
      name: "search_modules",
      description: "Search all Mooncakes modules. Use concise English technical keywords.",
      parameters: object_schema(
        {
          "query": string_field(
            "English package search keywords, for example: http client",
          ),
        },
        ["query"],
      ),
    },
    {
      name: "get_module_manifest",
      description: "Get live metadata for one exact module, including downloads, versions, build status and license.",
      parameters: object_schema(
        {
          "name": string_field(
            "Exact owner/module name returned by search_modules",
          ),
        },
        ["name"],
      ),
    },
    {
      name: "get_module_index",
      description: "List packages and public symbol names for an exact module version. Call this before requesting package docs.",
      parameters: object_schema(
        {
          "name": string_field("Exact owner/module name"),
          "version": string_field("Exact version from the manifest"),
        },
        ["name", "version"],
      ),
    },
    {
      name: "get_package_docs",
      description: "Get compact public API signatures and docstrings for one package returned by get_module_index.",
      parameters: object_schema(
        {
          "name": string_field("Exact owner/module name"),
          "version": string_field("Exact version from the manifest"),
          "package_path": string_field(
            "Exact full package path returned by get_module_index",
          ),
        },
        ["name", "version", "package_path"],
      ),
    },
  ]
}
