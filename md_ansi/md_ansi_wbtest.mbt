///|
fn render_checked(md : String) -> String {
  render_md_to_ansi(md) catch {
    _ => ""
  }
}

///|
test "render_heading_bold_and_code" {
  let out = render_checked("# Hello\n\n**bold** and `code`")
  assert_true(out.contains("\u001B[1m\u001B[36mHello\u001B[0m"))
  assert_true(out.contains("\u001B[1mbold\u001B[22m"))
  assert_true(out.contains("\u001B[7mcode\u001B[27m"))
}

///|
test "render_cjk_bold_with_spaces_fallback" {
  // Upstream cmark fails to parse emphasis around CJK+space text; the
  // renderer falls back to fixing the leftover markers itself.
  let out = render_checked("**API 用法** 和 **了解 API 用法**")
  assert_true(out.contains("\u001B[1mAPI 用法\u001B[22m"))
  assert_true(out.contains("\u001B[1m了解 API 用法\u001B[22m"))
  assert_false(out.contains("**"))
}

///|
test "render_cjk_italic_and_list_item" {
  let out = render_checked(
    "- **了解 API 用法** — 查询签名\n\n*中文 斜体*",
  )
  assert_true(out.contains("\u001B[1m了解 API 用法\u001B[22m"))
  assert_true(out.contains("\u001B[3m中文 斜体\u001B[23m"))
  assert_false(out.contains("**"))
}

///|
test "render_link_shows_destination" {
  let out = render_checked("[docs](https://mooncakes.io)")
  assert_true(out.contains("docs"))
  assert_true(out.contains("\u001B[4mhttps://mooncakes.io\u001B[24m"))
}

///|
test "render_code_block_reverse_video" {
  let out = render_checked("```moonbit\nlet x = 1\n```")
  assert_true(out.contains("\u001B[7mlet x = 1"))
  assert_true(out.contains("\u001B[0m"))
}

///|
test "render_list_and_quote" {
  let out = render_checked("- 甲\n- 乙\n\n> 引用")
  assert_true(out.contains("\u001B[2m- \u001B[0m甲"))
  assert_true(out.contains("\u001B[2m- \u001B[0m乙"))
  assert_true(out.contains("引用"))
}

///|
test "stream_flushes_blocks_on_blank_line" {
  let p = MdStreamPrinter::new()
  p.feed("第一段")
  p.feed("内容\n\n第二段")
  p.feed("内容")
  p.finish()
  let out = p.take_output()
  assert_true(out.contains("第一段内容"))
  assert_true(out.contains("第二段内容"))
}

///|
test "stream_passes_code_block_through" {
  let p = MdStreamPrinter::new()
  p.feed("```moonbit")
  p.feed("\nlet x = 1\n")
  p.feed("```\n")
  p.finish()
  let out = p.take_output()
  assert_true(out.contains("\u001B[7m```moonbit"))
  assert_true(out.contains("let x = 1"))
  assert_true(out.contains("\u001B[0m```"))
}

///|
test "stream_matches_whole_document_render" {
  let md =
    #|# 标题
    #|
    #|一段 **加粗** 和 *斜体*，还有 `code`。
    #|
    #|- 列表项甲
    #|- 列表项乙
    #|
    #|> 引用内容
  let expected = render_checked(md)
  let p = MdStreamPrinter::new()
  for i = 0; i < md.length(); i = i + 7 {
    let hi = if i + 7 < md.length() { i + 7 } else { md.length() }
    p.feed(md[i:hi].to_owned())
  }
  p.finish()
  assert_eq(p.take_output(), expected)
}

///|
test "render_cjk_fallback_edge_cases" {
  // underscore variants of the CJK+space fallback
  let out = render_checked("__中文 测试__ 和 _中文 测试_")
  assert_true(out.contains("\u001B[1m中文 测试\u001B[22m"))
  assert_true(out.contains("\u001B[3m中文 测试\u001B[23m"))
  assert_false(out.contains("__"))
  assert_false(out.contains("_中文"))
}

///|
test "render_fallback_does_not_touch_ascii_math_or_nested_stars" {
  // Space-separated multiplication is not emphasis to cmark, and the
  // fallback must not style it either (its content has no CJK).
  let mult = render_checked("2 * 3 * 4")
  assert_false(mult.contains("\u001B[3m"))
  assert_true(mult.contains("*"))
  // content containing a star is not wrapped by the fallback
  let nested = render_checked("**a*b**")
  assert_false(nested.contains("\u001B[1ma*b\u001B[22m"))
}

///|
test "render_fallback_leaves_cross_code_span_emphasis_alone" {
  // cmark parses the code span but not the surrounding **; the fallback
  // runs per Text node and cannot wrap across nodes, so the surrounding
  // text must not be turned into bold.
  let out = render_checked("**`code` 中文**")
  assert_true(out.contains("\u001B[7mcode\u001B[27m"))
  assert_false(out.contains("\u001B[1mcode"))
}
