///|
/// An OpenAI-compatible function tool schema.
pub(all) struct ToolSchema {
  name : String
  description : String
  parameters : Json
}

///|
pub fn ToolSchema::to_json(self : ToolSchema) -> Json {
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
pub fn string_field(description : String) -> Json {
  Json::object({
    "type": Json::string("string"),
    "description": Json::string(description),
  })
}

///|
pub fn object_schema(
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
pub fn argument_string(arguments : String, key : String) -> String raise {
  let document = @json.parse(arguments)
  guard document is Object(fields) else {
    fail("tool arguments must be a JSON object")
  }
  guard fields.get(key) is Some(String(value)) else {
    fail("missing string argument: \{key}")
  }
  value
}

///|
pub fn error_json(message : String) -> String {
  Json::object({ "error": Json::string(message) }).stringify()
}

///|

///|
pub(all) struct Tool {
  schema : ToolSchema
  execute : async (String) -> String
}

///|
// Run the tool with the given JSON arguments.
pub async fn Tool::run(self : Tool, arguments : String) -> String {
  (self.execute)(arguments)
}

///|
// Find a tool by name, or `None` when the model calls an unknown tool.
pub fn find_tool(tools : Array[Tool], name : String) -> Tool? {
  for t in tools {
    if t.schema.name == name {
      return Some(t)
    }
  }
  None
}
