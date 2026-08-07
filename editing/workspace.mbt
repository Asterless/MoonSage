///|
// agent 当前操作的目录：读写 / 克隆 / 发布工具都跟随这个根目录。
// 用 1 元素 Array 充当共享可变单元，保证工具闭包之间同步。
pub(all) struct Workspace {
  root : Array[String]
  base : String
  // 可撤销编辑栈：栈顶为最近一次编辑。
  undo_stack : Array[EditRecord]
}

///|
// 一次可撤销编辑：path 与写入前的原始内容；content 为 None 表示文件原本不存在。
struct EditRecord {
  path : String
  content : String?
}

///|
pub fn Workspace::new(root : String) -> Workspace {
  { root: [root], base: root + "/.moonsage/workspaces", undo_stack: [] }
}

///|
pub fn Workspace::get_root(self : Workspace) -> String {
  self.root[0]
}

///|
pub fn Workspace::set_root(self : Workspace, path : String) -> Unit {
  self.root[0] = path
}

///|
// clone 目标的基础目录。
pub fn Workspace::clone_base(self : Workspace) -> String {
  self.base
}

///|
// 记录一次可撤销编辑（写入前的原始内容；文件原本不存在时 content 为 None）。
pub fn Workspace::push_undo(
  self : Workspace,
  path : String,
  content : String?,
) -> Unit {
  self.undo_stack.push({ path, content })
}

///|
// 撤销最近一次编辑：恢复原始内容（原本不存在的文件则删除），返回描述文本。
pub async fn Workspace::undo(self : Workspace) -> String {
  match self.undo_stack.pop() {
    None => "nothing to undo"
    Some(record) => {
      let path = @util.safe_path(self.get_root(), record.path)
      match record.content {
        Some(content) => {
          @fs.write_file(
            path,
            content,
            create_mode=@fs.CreateMode::CreateOrTruncate,
          )
          "undid edit to \{record.path}"
        }
        None => {
          // 文件原本不存在：撤销创建/覆盖。
          @fs.remove(path) catch {
            _ => ()
          }
          "undid creation of \{record.path}"
        }
      }
    }
  }
}

///|
// 目录是否存在（@fs.kind 对缺失路径会抛错，这里统一转为 Bool）。
pub async fn dir_exists(path : String) -> Bool {
  try {
    let kind = @fs.kind(path)
    kind is @fs.FileKind::Directory
  } catch {
    _ => false
  }
}
