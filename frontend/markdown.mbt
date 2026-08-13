///|
fn inline_markdown_view(
  inline : @cmark.Inline,
  definitions : Map[String, @cmark.LabelDef],
) -> Array[Html] {
  match inline {
    Text(node) => [@html.text(node.v)]
    Inlines(node) =>
      node.v.fold(init=[], (output, child) => {
        output + inline_markdown_view(child, definitions)
      })
    Break(_) => [@html.br()]
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
    ExtTable(_) | ExtFootnoteDefinition(_) => []
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
