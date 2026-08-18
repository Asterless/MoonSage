///|
test "compact module index keeps package paths and public symbols" {
  let input =
    #|{
    #|  "name": "owner",
    #|  "package": null,
    #|  "childs": [{
    #|    "name": "module",
    #|    "package": null,
    #|    "childs": [{
    #|      "name": "client",
    #|      "package": {
    #|        "path": "owner/module/client",
    #|        "traits": [{"name": "Transport"}],
    #|        "errors": [{"name": "ClientError"}],
    #|        "types": [{"name": "Client"}],
    #|        "values": ["connect"]
    #|      },
    #|      "childs": []
    #|    }]
    #|  }]
    #|}
  let result = compact_module_index(input)
  assert_true(result.contains("owner/module/client"))
  assert_true(result.contains("Transport"))
  assert_true(result.contains("Client"))
  assert_true(result.contains("connect"))
}

///|
test "compact package docs keeps signatures and methods" {
  let input =
    #|{
    #|  "name": "owner/module/client",
    #|  "traits": [],
    #|  "errors": [],
    #|  "types": [{
    #|    "name": "Client",
    #|    "docstring": "An HTTP client.",
    #|    "signature": "pub struct Client",
    #|    "methods": [{
    #|      "name": "send",
    #|      "docstring": "Send one request.",
    #|      "signature": "async fn Client::send(Self, Request) -> Response"
    #|    }]
    #|  }],
    #|  "values": [{
    #|    "name": "connect",
    #|    "docstring": "Open a connection.",
    #|    "signature": "async fn connect(String) -> Client"
    #|  }]
    #|}
  let result = compact_package_docs(input)
  assert_true(result.contains("Client::send"))
  assert_true(result.contains("Send one request."))
  assert_true(result.contains("async fn connect"))
}

///|
test "compact module index caps at 80 packages" {
  let packages : Array[Json] = []
  for i = 0; i < 81; i = i + 1 {
    packages.push(
      Json::object({
        "name": Json::string("package\{i}"),
        "package": Json::object({
          "path": Json::string("owner/module/package\{i}"),
          "traits": Json::array([]),
          "errors": Json::array([]),
          "types": Json::array([]),
          "values": Json::array([]),
        }),
        "childs": Json::array([]),
      }),
    )
  }
  let root = Json::object({
    "name": Json::string("owner"),
    "package": Json::null(),
    "childs": Json::array([
      Json::object({
        "name": Json::string("module"),
        "package": Json::null(),
        "childs": Json::array(packages),
      }),
    ]),
  })
  let result = compact_module_index(root.stringify())
  assert_true(result.contains("package79"))
  assert_true(!result.contains("package80"))
}

///|
test "compact package docs caps at 100 entries" {
  let types : Array[Json] = []
  for i = 0; i < 101; i = i + 1 {
    types.push(
      Json::object({
        "name": Json::string("Type\{i}"),
        "docstring": Json::string(""),
        "signature": Json::string("pub struct Type\{i}"),
        "methods": Json::array([]),
      }),
    )
  }
  let doc = Json::object({
    "name": Json::string("owner/module/client"),
    "traits": Json::array([]),
    "errors": Json::array([]),
    "types": Json::array(types),
    "values": Json::array([]),
  })
  let result = compact_package_docs(doc.stringify())
  assert_true(result.contains("Type99"))
  assert_true(!result.contains("Type100"))
}

///|
test "compact package docs rejects non-object input" {
  let raised = try {
    ignore(compact_package_docs("[]"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "parse modules rejects non-array input" {
  let raised = try {
    ignore(parse_modules("{}"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}
