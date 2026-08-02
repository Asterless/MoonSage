///|
fn agent_tools() -> Array[@llm.Tool] {
  [
    @llm.Tool::with_schema(
      "search_modules",
      "Search all Mooncakes modules. Use concise English technical keywords.",
      @llm.Schema::object(
        fields=[
          (
            "query",
            @llm.Schema::string(
              description="English package search keywords, for example: http client",
            ),
          ),
        ],
        required=["query"],
      ),
    ),
    @llm.Tool::with_schema(
      "get_module_manifest",
      "Get live metadata for one exact module, including downloads, versions, build status and license.",
      @llm.Schema::object(
        fields=[
          (
            "name",
            @llm.Schema::string(
              description="Exact owner/module name returned by search_modules",
            ),
          ),
        ],
        required=["name"],
      ),
    ),
    @llm.Tool::with_schema(
      "get_module_index",
      "List packages and public symbol names for an exact module version. Call this before requesting package docs.",
      @llm.Schema::object(
        fields=[
          ("name", @llm.Schema::string(description="Exact owner/module name")),
          (
            "version",
            @llm.Schema::string(description="Exact version from the manifest"),
          ),
        ],
        required=["name", "version"],
      ),
    ),
    @llm.Tool::with_schema(
      "get_package_docs",
      "Get compact public API signatures and docstrings for one package returned by get_module_index.",
      @llm.Schema::object(
        fields=[
          ("name", @llm.Schema::string(description="Exact owner/module name")),
          (
            "version",
            @llm.Schema::string(description="Exact version from the manifest"),
          ),
          (
            "package_path",
            @llm.Schema::string(
              description="Exact full package path returned by get_module_index",
            ),
          ),
        ],
        required=["name", "version", "package_path"],
      ),
    ),
  ]
}
