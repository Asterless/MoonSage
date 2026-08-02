///|
fn json_string(value : Json, key : String) -> String {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

///|
fn json_strings(value : Json, key : String) -> Array[String] {
  let result : Array[String] = []
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(Array(items)) =>
          for item in items {
            if item is String(text) {
              result.push(text)
            }
          }
        _ => ()
      }
    _ => ()
  }
  result
}

///|
fn json_names(value : Json, key : String) -> Array[String] {
  let result : Array[String] = []
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(text) => result.push(text)
              Object(_) => {
                let name = json_string(item, "name")
                if name != "" {
                  result.push(name)
                }
              }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  result
}
