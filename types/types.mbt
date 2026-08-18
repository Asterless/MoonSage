///|
pub(all) struct ModuleSummary {
  name : String
  version : String
  license : String
  repository : String
  keywords : Array[String]
  description : String
  created_at : String
} derive(Eq, Debug, ToJson)

///|
pub(all) struct SearchResult {
  item : ModuleSummary
  score : Int
} derive(Eq, Debug, ToJson)

///|
pub(all) enum SearchEvent {
  Plan(String)
  ToolCall(String)
  Observation(String)
} derive(Eq, Debug)

///|
pub(all) struct SearchAnswer {
  query : String
  events : Array[SearchEvent]
  results : Array[SearchResult]
} derive(Eq, Debug)

///|
pub(all) struct PackageIndexSummary {
  path : String
  traits : Array[String]
  errors : Array[String]
  types : Array[String]
  values : Array[String]
} derive(Eq, Debug, ToJson)

///|
pub(all) struct PackageApiEntry {
  kind : String
  name : String
  signature : String
  docstring : String
} derive(Eq, Debug, ToJson)

///|
pub(all) struct PackageDocsSummary {
  name : String
  entries : Array[PackageApiEntry]
  truncated : Bool
} derive(Eq, Debug, ToJson)
