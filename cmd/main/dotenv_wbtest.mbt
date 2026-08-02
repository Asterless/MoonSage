///|
test "parse_env_line handles values, quotes, comments and blanks" {
  assert_eq(
    parse_env_line("MOONSAGE_API_KEY=abc123"),
    Some(("MOONSAGE_API_KEY", "abc123")),
  )
  assert_eq(
    parse_env_line("MOONSAGE_API_KEY = abc123"),
    Some(("MOONSAGE_API_KEY", "abc123")),
  )
  assert_eq(
    parse_env_line("KEY=\"quoted value\""),
    Some(("KEY", "quoted value")),
  )
  assert_eq(parse_env_line("KEY='single'"), Some(("KEY", "single")))
  assert_eq(parse_env_line("# comment"), None)
  assert_eq(parse_env_line(""), None)
  assert_eq(parse_env_line("no-equals-here"), None)
  assert_eq(parse_env_line("=missing-key"), None)
}

///|
test "parse_env_content collects pairs across lines" {
  let content =
    #|# MoonSage config
    #|MOONSAGE_API_KEY=secret
    #|
    #|MOONSAGE_BASE_URL = "https://example.com"
    #|MOONSAGE_MODEL=deepseek-chat
  let parsed = parse_env_content(content)
  assert_eq(parsed.length(), 3)
  assert_eq(parsed[0], ("MOONSAGE_API_KEY", "secret"))
  assert_eq(parsed[1], ("MOONSAGE_BASE_URL", "https://example.com"))
  assert_eq(parsed[2], ("MOONSAGE_MODEL", "deepseek-chat"))
}

///|
async test "load_dotenv loads values but never overrides the environment" {
  @sys.unset_env_var("MOONSAGE_TEST_OVERRIDE_KEY")
  let path = "_build/.env.override.test"
  let file = @fs.open(path, mode=WriteOnly, create_mode=CreateOrTruncate)
  file.write("MOONSAGE_TEST_OVERRIDE_KEY=from-file\n")
  file.close()
  @sys.set_env_var("MOONSAGE_TEST_OVERRIDE_KEY", "from-env")
  load_dotenv(path)
  assert_eq(@sys.get_env_var("MOONSAGE_TEST_OVERRIDE_KEY"), Some("from-env"))
  @sys.unset_env_var("MOONSAGE_TEST_OVERRIDE_KEY")
}

///|
async test "load_dotenv loads a value when the environment is unset" {
  @sys.unset_env_var("MOONSAGE_TEST_LOAD_KEY")
  let path = "_build/.env.load.test"
  let file = @fs.open(path, mode=WriteOnly, create_mode=CreateOrTruncate)
  file.write("MOONSAGE_TEST_LOAD_KEY=from-file\n")
  file.close()
  load_dotenv(path)
  assert_eq(@sys.get_env_var("MOONSAGE_TEST_LOAD_KEY"), Some("from-file"))
  @sys.unset_env_var("MOONSAGE_TEST_LOAD_KEY")
}
