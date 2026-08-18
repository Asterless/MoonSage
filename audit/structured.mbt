///|
pub(all) enum AuditRunStatus {
  Completed
  Failed
} derive(Eq, Debug)

///|
pub fn AuditRunStatus::to_string(self : AuditRunStatus) -> String {
  match self {
    Completed => "completed"
    Failed => "failed"
  }
}

///|
pub(all) struct StructuredAuditResult {
  status : AuditRunStatus
  project_dir : String
  report : String
  analysis : String
  diff : String
  evidence : AuditEvidence
  validation : AuditVerificationSummary
  needs_review : Bool
  error : String
}

///|
pub fn StructuredAuditResult::publishable(self : StructuredAuditResult) -> Bool {
  self.status is Completed &&
  self.diff.trim().length() > 0 &&
  self.evidence.verified &&
  self.evidence.conflicts.is_empty() &&
  !self.needs_review &&
  self.validation.passed()
}

///|
pub(all) struct AuditPackageResult {
  module_name : String
  owner : String
  repo : String
  workspace : String
  project_dir : String
  source_revision : String
  skipped : Bool
  audit : StructuredAuditResult
}

///|
pub async fn ignore_audit_stage(_stage : String) -> Unit {
  @async.sleep(0)
}

///|
async fn never_skip_package(
  _owner : String,
  _repo : String,
  _revision : String,
) -> Bool {
  false
}

///|
async fn source_revision(project_dir : String) -> String {
  let (exit, output, _) = @process.collect_output(
    "git",
    ["rev-parse", "HEAD"],
    cwd=project_dir,
    extra_env=audit_repo_environment(),
    inherit_env=false,
    no_console_window=true,
  ) catch {
    _ => return ""
  }
  if exit == 0 {
    (output.text() catch { _ => "" }).trim().to_owned()
  } else {
    ""
  }
}

///|
fn empty_validation_result() -> AuditVerificationSummary {
  {
    check_passed: false,
    build_passed: false,
    test_passed: false,
    check_output: "",
    build_output: "",
    test_output: "",
  }
}

///|
fn empty_audit_evidence() -> AuditEvidence {
  { tools: [], verification_ran: false, verified: false, conflicts: [] }
}

///|
fn finalize_controller_evidence(
  evidence : AuditEvidence,
  before_diff : String,
  final_diff : String,
) -> AuditEvidence {
  let conflicts = evidence.conflicts.copy()
  let mut verified = evidence.verified
  if before_diff == "(git diff failed)" || final_diff == "(git diff failed)" {
    verified = false
    conflicts.push("The controller could not read the final Git diff.")
  } else if before_diff != final_diff {
    verified = false
    conflicts.push(
      "The worktree changed during controller-owned verification; the final diff was not verified.",
    )
  }
  { ..evidence, verified, conflicts }
}

///|
// 修复 Agent 可能在工具预算耗尽后没有调用 run_moon 作为最终验证。此时
// controller 已对最终 worktree 独立执行 check/build/test；只要验证通过且
// 没有其他证据冲突，就以 controller 验证作为权威的修复后证据，避免把
// “Agent 未亲自验证”误判为审计失败。
fn finalize_with_controller_verification(
  evidence : AuditEvidence,
  validation : AuditVerificationSummary,
) -> AuditEvidence {
  if validation.passed() &&
    evidence.conflicts.all(fn(conflict) {
      conflict.contains("No post-fix moon verification command was run")
    }) {
    { ..evidence, verification_ran: true, verified: true, conflicts: [] }
  } else {
    evidence
  }
}

///|
fn structured_failure(
  project_dir : String,
  message : String,
) -> StructuredAuditResult {
  {
    status: Failed,
    project_dir,
    report: "",
    analysis: "",
    diff: "",
    evidence: empty_audit_evidence(),
    validation: empty_validation_result(),
    needs_review: false,
    error: message,
  }
}

///|
/// Execute the existing two-phase audit/fix agent against an already prepared
/// local MoonBit project and return structured evidence. It never creates a
/// commit, pushes a branch, or invokes GitHub CLI.
pub async fn run_structured_audit_project(
  api_key : String,
  base_url : String,
  model : String,
  project_dir : String,
  max_tool_calls? : Int = 80,
  max_rounds? : Int = 8,
  timeout_ms? : Int = 20 * 60 * 1000,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  on_stage? : async (String) -> Unit = ignore_audit_stage,
  provider? : @ai.ProviderKind = OpenAi,
) -> StructuredAuditResult {
  guard api_key != "" else {
    return structured_failure(project_dir, "MOONSAGE_API_KEY is required")
  }
  guard max_tool_calls > 0 && max_rounds > 0 && timeout_ms > 0 else {
    return structured_failure(project_dir, "audit budgets must be positive")
  }
  guard is_moon_project(project_dir) else {
    return structured_failure(project_dir, "workspace has no moon.mod")
  }
  let ctx : AuditContext = { project_dir, fix: true, confirm: ConfirmYes }
  on_stage("auditing") catch {
    _ => ()
  }
  let analysis_events : Array[@runtime.EngineEvent] = []
  let analysis = run_analysis_agent(
    api_key,
    base_url,
    model,
    ctx,
    on_event=async fn(event) {
      analysis_events.push(event)
      on_event(event)
    },
    restricted_moon=true,
    provider~,
  ) catch {
    error => {
      let partial = @runtime.AgentAnswer::new("", [], analysis_events)
      return {
        ..structured_failure(project_dir, error.to_string()),
        evidence: build_audit_evidence(None, partial, false),
      }
    }
  }
  on_stage("fixing") catch {
    _ => ()
  }
  let fix_events : Array[@runtime.EngineEvent] = []
  let answer = run_fix_agent(
    api_key,
    base_url,
    model,
    ctx,
    analysis.text,
    max_tool_calls~,
    max_rounds~,
    on_event=async fn(event) {
      fix_events.push(event)
      on_event(event)
    },
    restricted_moon=true,
    provider~,
  ) catch {
    error => {
      let partial = @runtime.AgentAnswer::new("", [], fix_events)
      return {
        ..structured_failure(project_dir, error.to_string()),
        analysis: analysis.text,
        evidence: build_audit_evidence(Some(analysis), partial, true),
      }
    }
  }
  let evidence = build_audit_evidence(Some(analysis), answer, true)
  let before_diff = @local.git_diff(project_dir, None)
  on_stage("verifying") catch {
    _ => ()
  }
  let validation = run_final_audit_verification(project_dir, timeout_ms~)
  let diff = @local.git_diff(project_dir, None)
  let evidence = finalize_controller_evidence(evidence, before_diff, diff)
  let evidence = finalize_with_controller_verification(evidence, validation)
  let needs_review = audit_self_review_needs_review(evidence)
  {
    status: Completed,
    project_dir,
    report: answer.text,
    analysis: analysis.text,
    diff,
    evidence,
    validation,
    needs_review,
    error: "",
  }
}

///|
/// Resolve a Mooncakes manifest, clone a dedicated full Git repository and run
/// the structured audit. The returned workspace remains caller-owned so the
/// publishing controller can inspect and publish the exact verified tree.
pub async fn run_structured_audit_package(
  api_key : String,
  base_url : String,
  model : String,
  module_name : String,
  workspace? : String = "",
  max_tool_calls? : Int = 80,
  max_rounds? : Int = 8,
  timeout_ms? : Int = 20 * 60 * 1000,
  on_event? : async (@runtime.EngineEvent) -> Unit = @runtime.ignore_event,
  on_stage? : async (String) -> Unit = ignore_audit_stage,
  provider? : @ai.ProviderKind = OpenAi,
  should_skip? : async (String, String, String) -> Bool = never_skip_package,
) -> AuditPackageResult {
  on_stage("fetching") catch {
    _ => ()
  }
  let actual_workspace = if workspace == "" {
    @fs.tmpdir(prefix="moonsage-mode1-")
  } else {
    @fs.mkdir(workspace, recursive=true) catch {
      error =>
        return {
          module_name,
          owner: "",
          repo: "",
          workspace,
          project_dir: "",
          source_revision: "",
          skipped: false,
          audit: structured_failure("", error.to_string()),
        }
    }
    workspace
  }
  guard @mooncakes.valid_module_name(module_name) else {
    return {
      module_name,
      owner: "",
      repo: "",
      workspace: actual_workspace,
      project_dir: "",
      source_revision: "",
      skipped: false,
      audit: structured_failure("", "invalid Mooncakes module name"),
    }
  }
  let manifest = @mooncakes.fetch_asset(
    "https://mooncakes.io/api/v0/manifest/\{module_name}",
    "Mooncakes manifest API",
  ) catch {
    error =>
      return {
        module_name,
        owner: "",
        repo: "",
        workspace: actual_workspace,
        project_dir: "",
        source_revision: "",
        skipped: false,
        audit: structured_failure("", error.to_string()),
      }
  }
  let repository = manifest_repository(manifest) catch {
    error =>
      return {
        module_name,
        owner: "",
        repo: "",
        workspace: actual_workspace,
        project_dir: "",
        source_revision: "",
        skipped: false,
        audit: structured_failure("", error.to_string()),
      }
  }
  guard parse_github_repo(repository) is Some((owner, repo)) else {
    return {
      module_name,
      owner: "",
      repo: "",
      workspace: actual_workspace,
      project_dir: "",
      source_revision: "",
      skipped: false,
      audit: structured_failure("", "unsupported repository: \{repository}"),
    }
  }
  let project_dir = fetch_repo_source(owner, repo, actual_workspace, full=true) catch {
    error =>
      return {
        module_name,
        owner,
        repo,
        workspace: actual_workspace,
        project_dir: "",
        source_revision: "",
        skipped: false,
        audit: structured_failure("", error.to_string()),
      }
  }
  let revision = source_revision(project_dir)
  if should_skip(owner, repo, revision) {
    return {
      module_name,
      owner,
      repo,
      workspace: actual_workspace,
      project_dir,
      source_revision: revision,
      skipped: true,
      audit: structured_failure(
        project_dir, "already processed with the same source revision and policy",
      ),
    }
  }
  let result = run_structured_audit_project(
    api_key,
    base_url,
    model,
    project_dir,
    max_tool_calls~,
    max_rounds~,
    timeout_ms~,
    on_event~,
    on_stage~,
    provider~,
  )
  {
    module_name,
    owner,
    repo,
    workspace: actual_workspace,
    project_dir,
    source_revision: revision,
    skipped: false,
    audit: result,
  }
}
