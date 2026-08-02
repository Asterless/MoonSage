///|
// ANSI SGR escape sequences used by the terminal renderer.
// Windows Terminal and modern consoles support these codes.
let ansi_reset = "\u001B[0m"

///|
let ansi_bold = "\u001B[1m"

///|
let ansi_bold_off = "\u001B[22m"

///|
let ansi_italic = "\u001B[3m"

///|
let ansi_italic_off = "\u001B[23m"

///|
let ansi_underline = "\u001B[4m"

///|
let ansi_underline_off = "\u001B[24m"

///|
let ansi_reverse = "\u001B[7m"

///|
let ansi_reverse_off = "\u001B[27m"

///|
let ansi_strike = "\u001B[9m"

///|
let ansi_strike_off = "\u001B[29m"

///|
let ansi_dim = "\u001B[2m"

///|
let ansi_cyan = "\u001B[36m"

///|
fn is_cjk_char(c : Char) -> Bool {
  let code = c.to_int()
  (code >= 0x3400 && code <= 0x4DBF) || // CJK 扩展 A
  (code >= 0x4E00 && code <= 0x9FFF) || // CJK 统一表意文字
  (code >= 0xF900 && code <= 0xFAFF) || // CJK 兼容表意文字
  (code >= 0x3000 && code <= 0x303F) || // CJK 标点
  (code >= 0xFF00 && code <= 0xFFEF) || // 全角形式
  (code >= 0x3040 && code <= 0x30FF) || // 日文假名
  (code >= 0xAC00 && code <= 0xD7AF) // 韩文音节
}

///|
fn contains_cjk(s : String) -> Bool {
  for c in s {
    if is_cjk_char(c) {
      return true
    }
  }
  false
}

///|
// Fallback for upstream cmark failing to parse emphasis around text that
// mixes CJK characters with spaces (e.g. `**API 用法**` is left as literal
// text). Only runs on leftover markers inside Text nodes, so code spans,
// code blocks and already-parsed emphasis are untouched.
fn fix_emphasis_pass(
  text : String,
  delim : Char,
  double~ : Bool,
  cjk_only~ : Bool,
) -> String {
  let out = StringBuilder::new()
  let len = text.length()
  let mut i = 0
  while i < len {
    if text[i].unsafe_to_char() == delim {
      let mut run = 1
      while i + run < len && text[i + run].unsafe_to_char() == delim {
        run += 1
      }
      if (run >= 2) != double {
        for k = 0; k < run; k = k + 1 {
          out.write_char(delim)
        }
        i = i + run
        continue
      }
      let min_close = if double { 2 } else { 1 }
      let mut j = i + run
      let mut close = -1
      let mut close_run = 0
      while j < len {
        if text[j].unsafe_to_char() == delim {
          let mut r2 = 1
          while j + r2 < len && text[j + r2].unsafe_to_char() == delim {
            r2 += 1
          }
          if r2 >= min_close {
            let x = text[i + run:j].to_owned()
            let valid = !x.is_empty() &&
              !x.contains_char(delim) &&
              !x.contains("\n") &&
              (!cjk_only || contains_cjk(x))
            if valid {
              close = j
              close_run = r2
              break
            }
          }
          j += r2
        } else {
          j += 1
        }
      }
      if close >= 0 {
        if double {
          out.write_string(ansi_bold)
          out.write_string(text[i + run:close].to_owned())
          out.write_string(ansi_bold_off)
        } else {
          out.write_string(ansi_italic)
          out.write_string(text[i + run:close].to_owned())
          out.write_string(ansi_italic_off)
        }
        i = close + close_run
        continue
      }
      for k = 0; k < run; k = k + 1 {
        out.write_char(delim)
      }
      i = i + run
    } else {
      out.write_char(text[i].unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
fn fix_emphasis(text : String) -> String {
  let s1 = fix_emphasis_pass(text, '*', double=true, cjk_only=false)
  let s2 = fix_emphasis_pass(s1, '_', double=true, cjk_only=false)
  let s3 = fix_emphasis_pass(s2, '*', double=false, cjk_only=true)
  fix_emphasis_pass(s3, '_', double=false, cjk_only=true)
}

///|
// State threaded through the renderer callbacks: the collected link
// definitions of the current document, used to resolve link destinations.
priv struct AnsiRenderState {
  defs : Map[String, @cmark.LabelDef]
}

///|
// Extend cmark's extensible context state with our own variant.
extenum @cmark_base.ContextState += {
  AnsiState(AnsiRenderState)
}

///|
fn init_ansi_context(c : @cmark_renderer.Context, doc : @cmark.Doc) -> Unit {
  c.state = Some(AnsiState({ defs: doc.block.defs() }))
}

///|
fn ansi_link_dest(
  c : @cmark_renderer.Context,
  link : @cmark.InlineLink,
) -> String? {
  guard c.state is Some(AnsiState({ defs }))
  match link.reference_definition(defs) {
    Some(@cmark.LinkDef(nd)) =>
      match nd.v.dest {
        Some(d) => Some(d.v)
        None => None
      }
    _ => None
  }
}

///|
fn render_ansi_block(
  c : @cmark_renderer.Context,
  b : @cmark.Block,
) -> Unit raise {
  match b {
    @cmark.Blocks(bs) =>
      for sub in bs.v {
        c.block(sub)
      }
    @cmark.Paragraph(p) => {
      c.inline(p.v.inline)
      c.string("\n")
    }
    @cmark.Heading(h) => {
      c.string(ansi_bold + ansi_cyan)
      c.inline(h.v.inline)
      c.string(ansi_reset + "\n")
    }
    @cmark.CodeBlock(cb) => {
      c.string(ansi_reverse)
      for line in cb.v.code {
        c.string(line.v)
        c.string("\n")
      }
      c.string(ansi_reset + "\n")
    }
    @cmark.List(l) =>
      for item in l.v.items {
        let marker = item.v.marker.v
        c.string("  " + ansi_dim + marker + " " + ansi_reset)
        match item.v.ext_task_marker {
          Some(mark) =>
            c.string(
              "[" +
              (if mark.v == 'x' || mark.v == 'X' { "x" } else { " " }) +
              "] ",
            )
          None => ()
        }
        c.block(item.v.block)
      }
    @cmark.BlockQuote(q) => {
      c.string(ansi_dim + "  | " + ansi_reset)
      c.block(q.v.block)
    }
    @cmark.ThematicBreak(_) =>
      c.string(
        ansi_dim +
        "───────────────────" +
        ansi_reset +
        "\n",
      )
    @cmark.BlankLine(_) | @cmark.LinkRefDefinition(_) | @cmark.HtmlBlock(_) =>
      ()
    @cmark.ExtMathBlock(m) => {
      c.string("$$ ")
      for line in m.v.code {
        c.string(line.v)
      }
      c.string(" $$\n")
    }
    @cmark.ExtTable(t) =>
      for row in t.v.rows {
        match row.0.v {
          @cmark.Header(cells) | @cmark.Data(cells) => {
            let arr = cells.to_array()
            for i = 0; i < arr.length(); i = i + 1 {
              c.inline(arr[i].0)
              c.string(" | ")
            }
            c.string("\n")
          }
          @cmark.Sep(_) => c.string("\n")
        }
      }
    @cmark.ExtFootnoteDefinition(_) => ()
  }
}

///|
fn render_ansi_inline(
  c : @cmark_renderer.Context,
  i : @cmark.Inline,
) -> Unit raise {
  match i {
    @cmark.Text(t) => c.string(fix_emphasis(t.v))
    @cmark.Inlines(inlines) =>
      for sub in inlines.v {
        c.inline(sub)
      }
    @cmark.StrongEmphasis(se) => {
      c.string(ansi_bold)
      c.inline(se.v.inline)
      c.string(ansi_bold_off)
    }
    @cmark.Emphasis(e) => {
      c.string(ansi_italic)
      c.inline(e.v.inline)
      c.string(ansi_italic_off)
    }
    @cmark.CodeSpan(cs) => {
      c.string(ansi_reverse)
      c.string(cs.v.code())
      c.string(ansi_reverse_off)
    }
    @cmark.Link(l) => {
      c.inline(l.v.text)
      match ansi_link_dest(c, l.v) {
        Some(url) =>
          c.string(" (" + ansi_underline + url + ansi_underline_off + ")")
        None => ()
      }
    }
    @cmark.Image(img) => {
      c.string("[img: ")
      c.inline(img.v.text)
      c.string("]")
    }
    @cmark.Autolink(a) => {
      c.string(ansi_underline)
      c.string(a.v.link.v)
      c.string(ansi_underline_off)
    }
    @cmark.Break(_) => c.string("\n")
    @cmark.RawHtml(_) => ()
    @cmark.ExtStrikethrough(s) => {
      c.string(ansi_strike)
      c.inline(s.v.0)
      c.string(ansi_strike_off)
    }
    @cmark.ExtMathSpan(m) => c.string("$" + m.v.tex() + "$")
  }
}

///|
// Render a complete Markdown document to a terminal-friendly ANSI string.
// The caller is responsible for resetting the style afterwards.
pub fn render_md_to_ansi(md : String) -> String raise {
  let renderer = @cmark_renderer.Renderer::new(
    init_context=init_ansi_context,
    inline=(c, i) => {
      render_ansi_inline(c, i)
      true
    },
    block=(c, b) => {
      render_ansi_block(c, b)
      true
    },
    doc=(c, doc) => {
      match doc.block {
        @cmark.Blocks(bs) => {
          let arr = bs.v.to_array()
          for i = 0; i < arr.length(); i = i + 1 {
            if i > 0 {
              c.string("\n")
            }
            c.block(arr[i])
          }
        }
        b => c.block(b)
      }
      true
    },
  )
  let doc = @cmark.Doc::from_string(md)
  renderer.doc_to_string(doc)
}

///|
// Incremental Markdown -> ANSI printer for streaming text.
//
// Markdown blocks are delimited by blank lines (paragraphs, headings,
// lists), so the printer buffers lines and renders a completed chunk with
// `render_md_to_ansi` as soon as a blank line arrives. Fenced code blocks are
// passed through verbatim (reverse video) so long code stays responsive and
// is never re-parsed line by line. `take_output` drains whatever has been
// rendered so far; call `finish` at end-of-stream to flush the tail.
pub struct MdStreamPrinter {
  buffer : StringBuilder
  line : StringBuilder
  out : StringBuilder
  mut in_code_block : Bool
}

///|
pub fn MdStreamPrinter::new() -> MdStreamPrinter {
  {
    buffer: StringBuilder::new(),
    line: StringBuilder::new(),
    out: StringBuilder::new(),
    in_code_block: false,
  }
}

///|
fn is_code_fence(line : String) -> Bool {
  let t = line.trim()
  t.has_prefix("```") || t.has_prefix("~~~")
}

///|
fn MdStreamPrinter::flush_buffer(self : MdStreamPrinter) -> Unit {
  if self.buffer.is_empty() {
    return
  }
  let md = self.buffer.to_string()
  self.buffer.reset()
  let rendered = render_md_to_ansi(md) catch { _ => md }
  self.out.write_string(rendered)
}

///|
fn MdStreamPrinter::process_line(self : MdStreamPrinter, line : String) -> Unit {
  if self.in_code_block {
    if is_code_fence(line) {
      self.out.write_string(ansi_reset)
      self.out.write_string(line)
      self.out.write_string("\n")
      self.in_code_block = false
    } else {
      self.out.write_string(line)
      self.out.write_string("\n")
    }
    return
  }
  if is_code_fence(line) {
    self.flush_buffer()
    self.out.write_string(ansi_reverse)
    self.out.write_string(line)
    self.out.write_string("\n")
    self.in_code_block = true
  } else if line.trim().is_empty() {
    self.flush_buffer()
    self.out.write_string("\n")
  } else {
    self.buffer.write_string(line)
    self.buffer.write_string("\n")
  }
}

///|
// Feed the next chunk of streamed text. Completed Markdown blocks are
// rendered immediately and accumulated in the internal output buffer.
pub fn MdStreamPrinter::feed(self : MdStreamPrinter, text : String) -> Unit {
  for ch in text {
    if ch == '\n' {
      self.process_line(self.line.to_string())
      self.line.reset()
    } else {
      self.line.write_char(ch)
    }
  }
}

///|
// Flush the trailing buffer and close any still-open code block.
pub fn MdStreamPrinter::finish(self : MdStreamPrinter) -> Unit {
  if self.in_code_block {
    self.out.write_string(ansi_reset + "\n")
    self.in_code_block = false
  }
  if !self.line.is_empty() {
    self.buffer.write_string(self.line.to_string())
    self.line.reset()
  }
  self.flush_buffer()
}

///|
// Drain and clear the rendered output accumulated so far.
pub fn MdStreamPrinter::take_output(self : MdStreamPrinter) -> String {
  let s = self.out.to_string()
  self.out.reset()
  s
}
