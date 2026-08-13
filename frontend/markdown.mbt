///|
fn star_run_end(source : String, start : Int) -> Int {
  for index = start; index < source.length() && source[index] == '*'; {
    continue index + 1
  } nobreak {
    index
  }
}

///|
fn text_with_strong_fallback(source : String) -> Array[Html] {
  match source.find("**") {
    None => [@html.text(source)]
    Some(open) => {
      let run_end = star_run_end(source, open)
      if run_end - open > 2 {
        let output : Array[Html] = []
        let literal = source[:run_end].to_owned()
        if !literal.is_empty() {
          output.push(@html.text(literal))
        }
        let after = source[run_end:].to_owned()
        if after.is_empty() {
          output
        } else {
          output + text_with_strong_fallback(after)
        }
      } else {
        let content_start = open + 2
        let remainder = source[content_start:].to_owned()
        match remainder.find("**") {
          None => [@html.text(source)]
          Some(relative_close) => {
            let close = content_start + relative_close
            let content = source[content_start:close].to_owned()
            if content.trim().is_empty() {
              let output : Array[Html] = []
              output.push(@html.text(source[:close + 2].to_owned()))
              let after = source[close + 2:].to_owned()
              if after.is_empty() {
                output
              } else {
                output + text_with_strong_fallback(after)
              }
            } else {
              let output : Array[Html] = []
              let before = source[:open].to_owned()
              if !before.is_empty() {
                output.push(@html.text(before))
              }
              output.push(@html.strong([@html.text(content)]))
              let after = source[close + 2:].to_owned()
              if !after.is_empty() {
                output + text_with_strong_fallback(after)
              } else {
                output
              }
            }
          }
        }
      }
    }
  }
}

///|
fn inline_markdown_view(
  inline : @cmark.Inline,
  definitions : Map[String, @cmark.LabelDef],
) -> Array[Html] {
  match inline {
    Text(node) => text_with_strong_fallback(node.v)
    Inlines(node) =>
      node.v.fold(init=[], (output, child) => {
        output + inline_markdown_view(child, definitions)
      })
    Break(node) =>
      if node.v.ty == Hard {
        [@html.br()]
      } else {
        [@html.text(" ")]
      }
    CodeSpan(node) => [@html.code(node.v.code())]
    Emphasis(node) =>
      [@html.em(inline_markdown_view(node.v.inline, definitions))]
    StrongEmphasis(node) =>
      [@html.strong(inline_markdown_view(node.v.inline, definitions))]
    Link(node) => {
      let children = inline_markdown_view(node.v.text, definitions)
      match node.v.reference_definition(definitions) {
        Some(LinkDef(definition)) =>
          match definition.v.dest {
            Some(destination) if !@cmark.InlineLink::is_unsafe(destination.v) =>
              [
                @html.a(
                  href=destination.v,
                  target=Blank,
                  rel="noopener noreferrer",
                  children,
                ),
              ]
            _ => children
          }
        _ => children
      }
    }
    Autolink(node) => {
      let destination = if node.v.is_email {
        "mailto:" + node.v.link.v
      } else {
        node.v.link.v
      }
      if @cmark.InlineLink::is_unsafe(destination) {
        [@html.text(node.v.link.v)]
      } else {
        [
          @html.a(
            href=destination,
            target=Blank,
            rel="noopener noreferrer",
            node.v.link.v,
          ),
        ]
      }
    }
    Image(node) => inline_markdown_view(node.v.text, definitions)
    RawHtml(_) => []
    ExtStrikethrough(node) =>
      [@html.del(inline_markdown_view(node.v.0, definitions))]
    ExtMathSpan(node) => [@html.code(class="math", node.v.tex())]
  }
}

///|
fn markdown_table_cells_view(
  cells : @cmark.Seq[(@cmark.Inline, @cmark.TableCellLayout)],
  header : Bool,
  definitions : Map[String, @cmark.LabelDef],
) -> Array[Html] {
  cells
  .map(cell => {
    let children = inline_markdown_view(cell.0, definitions)
    if header {
      @html.th(children)
    } else {
      @html.td(children)
    }
  })
  .to_array()
}

///|
fn markdown_table_view(
  table : @cmark.Table,
  definitions : Map[String, @cmark.LabelDef],
) -> Html {
  let header_rows : Array[Html] = []
  let data_rows : Array[Html] = []
  for row in table.rows {
    match row.0.v {
      Header(cells) =>
        header_rows.push(
          @html.tr(markdown_table_cells_view(cells, true, definitions)),
        )
      Data(cells) =>
        data_rows.push(
          @html.tr(markdown_table_cells_view(cells, false, definitions)),
        )
      Sep(_) => ()
    }
  }
  let sections : Array[Html] = []
  if !header_rows.is_empty() {
    sections.push(@html.thead(header_rows))
  }
  if !data_rows.is_empty() {
    sections.push(@html.tbody(data_rows))
  }
  @html.div(class="markdown-table-scroll", [@html.table(sections)])
}

///|
fn markdown_list_item_view(
  item : @cmark.ListItem,
  definitions : Map[String, @cmark.LabelDef],
) -> Html {
  @html.li(markdown_block_views(item.block, definitions))
}

///|
fn markdown_block_views(
  block : @cmark.Block,
  definitions : Map[String, @cmark.LabelDef],
) -> Array[Html] {
  match block {
    BlankLine(_) | LinkRefDefinition(_) | HtmlBlock(_) => []
    Blocks(node) =>
      node.v.fold(init=[], (output, child) => {
        output + markdown_block_views(child, definitions)
      })
    Paragraph(node) =>
      [@html.p(inline_markdown_view(node.v.inline, definitions))]
    Heading(node) => {
      let children = inline_markdown_view(node.v.inline, definitions)
      match node.v.level {
        1 => [@html.h2(children)]
        2 => [@html.h2(children)]
        _ => [@html.h3(children)]
      }
    }
    BlockQuote(node) =>
      [@html.blockquote(markdown_block_views(node.v.block, definitions))]
    CodeBlock(node) | ExtMathBlock(node) => {
      let source = node.v.code
        .fold(init=StringBuilder::new(), (output, line) => {
          output.write_string(line.v)
          output.write_char('\n')
          output
        })
        .to_string()
      [@html.pre([@html.code(source)])]
    }
    List(node) => {
      let items = node.v.items
        .map(item => markdown_list_item_view(item.v, definitions))
        .to_array()
      match node.v.ty {
        Unordered(_) => [@html.ul(items)]
        Ordered(start, _) => [@html.ol(start~, items)]
      }
    }
    ThematicBreak(_) => [@html.hr()]
    ExtTable(node) => [markdown_table_view(node.v, definitions)]
    ExtFootnoteDefinition(_) => []
  }
}

///|
fn markdown_view(source : String) -> Html {
  let document = @cmark.Doc::from_string(source, strict=false)
  @html.div(
    class="message-text markdown",
    markdown_block_views(document.block, document.defs),
  )
}
