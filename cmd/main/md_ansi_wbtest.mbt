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
