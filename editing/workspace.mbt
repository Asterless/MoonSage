///|
// agent 当前操作的目录：读写 / 克隆 / 发布工具都跟随这个根目录。
// 用 1 元素 Array 充当共享可变单元，保证工具闭包之间同步。
pub(all) struct Workspace {
  root : Array[String]
  base : String
}

///|
pub fn Workspace::new(root : String) -> Workspace {
  { root: [root], base: root + "/.moonsage/workspaces" }
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
// 目录是否存在（@fs.kind 对缺失路径会抛错，这里统一转为 Bool）。
pub async fn dir_exists(path : String) -> Bool {
  try {
    let kind = @fs.kind(path)
    kind is @fs.FileKind::Directory
  } catch {
    _ => false
  }
}
