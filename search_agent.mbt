///|
pub fn run_search_agent(
  modules : Array[ModuleSummary],
  query : String,
  limit? : Int = 5,
) -> SearchAnswer {
  let events = [
    Plan("Search Mooncakes metadata, rank candidates, then cite package pages"),
    ToolCall("search_modules(query=\"\{query}\", limit=\{limit})"),
  ]
  let results = search_modules(modules, query, limit~)
  events.push(Observation("\{results.length()} matching modules selected"))
  { query, events, results }
}

///|
pub fn package_url(name : String) -> String {
  "https://mooncakes.io/docs/\{name}"
}

///|
pub fn render_search_answer(answer : SearchAnswer) -> String {
  let out = StringBuilder::new()
  out.write_string("MoonSage\n\n")
  for event in answer.events {
    match event {
      Plan(text) => out.write_string("[plan] \{text}\n")
      ToolCall(text) => out.write_string("[tool] \{text}\n")
      Observation(text) => out.write_string("[observation] \{text}\n")
    }
  }
  out.write_string("\n")
  if answer.results.is_empty() {
    out.write_string(
      "No matching modules found. Try more specific English keywords.\n",
    )
  } else {
    let mut index = 1
    for result in answer.results {
      let item = result.item
      out.write_string("\{index}. \{item.name} \{item.version}\n")
      if item.description != "" {
        out.write_string("   \{item.description}\n")
      }
      out.write_string("   license: \{item.license} | score: \{result.score}\n")
      out.write_string("   \{package_url(item.name)}\n")
      index += 1
    }
  }
  out.to_string()
}
