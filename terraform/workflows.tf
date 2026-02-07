
# -----------------------------------------------------------------------------
# Dataformトリガー用 Cloud Workflows
# -----------------------------------------------------------------------------

# --- Workflows用サービスアカウント ---
resource "google_service_account" "workflows_sa" {
  account_id   = "dataform-workflows-sa${local.env_suffix}"
  display_name = "Dataform Workflows Service Account${local.env_suffix}"
  project      = var.project_id
}

# Workflowsサービスアカウントへの権限付与
resource "google_project_iam_member" "workflows_dataform_editor" {
  project = var.project_id
  role    = "roles/dataform.editor"
  member  = "serviceAccount:${google_service_account.workflows_sa.email}"
}

resource "google_project_iam_member" "workflows_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.workflows_sa.email}"
}

# --- Cloud Workflow ---
resource "google_workflows_workflow" "dataform_trigger_workflow_stg" {
  count           = terraform.workspace != "prd" ? 1 : 0
  depends_on      = [google_project_service.workflows]
  name            = "dataform-trigger-workflow-stg"
  region          = var.region
  description     = "BigQueryテーブル更新時にDataform実行をトリガーするワークフロー (Staging)"
  service_account = google_service_account.workflows_sa.id
  project         = var.project_id

  source_contents = <<EOF
main:
  params: [args]
  steps:
    - init:
        assign:
          - is_paused: false  # 停止したい時はここを true に、再開時は false にする
          - repository: "projects/${var.project_id}/locations/${var.region}/repositories/${google_dataform_repository.repository_stg[0].name}"
          - workspace: "${var.dataform_workspace_id}"
    - check_paused:
        switch:
          - condition: $${is_paused}
            return: "Paused: Dataform execution skipped."
    - createCompilationResult:
        call: http.post
        args:
          url: $${"https://dataform.googleapis.com/v1beta1/" + repository + "/compilationResults"}
          auth:
            type: OAuth2
          body:
            gitCommitish: "main"
            codeCompilationConfig:
              defaultDatabase: "${var.project_id}"
              defaultSchema: "${var.stg_schema}"
              vars:
                source_schema: "kolbi_keiba_stg"
        result: compilationResult
    - createWorkflowInvocation:
        call: http.post
        args:
          url: $${"https://dataform.googleapis.com/v1beta1/" + repository + "/workflowInvocations"}
          auth:
            type: OAuth2
          body:
            compilationResult: $${compilationResult.body.name}
            invocationConfig:
              includedTags: $${default(map.get(args, "tags"), [])}
              serviceAccount: "dataform-runner-stg@${var.project_id}.iam.gserviceaccount.com"
        result: workflowInvocation
    # Dataform実行完了を待つロジックが必要だが、非同期呼出のままにするか、Dataform完了をポーリングするか。
    # 既存コードはInvocation作成だけしてリターンしているため、Dataformの完了を待っていない。
    # しかし、scheduleテーブルが更新された「後」にExportしたいなら、Dataformの完了を待つ必要がある。
    # ここでは既存Workflowの振る舞いに従い、Triggerのみを行うか、それとも待機するか？
    # Use Case: "Export added or updated records... whenever the table is updated."
    # The table is updated BY Dataform. So we MUST wait for Dataform to finish.
    # Current workflow only triggers Dataform.
    # To properly implement "Export after Update", we need to wait for Dataform completion.
    # Let's add polling logic.
    - waitForDataform:
        call: sys.sleep
        args:
          seconds: 30
    - checkDataformStatus:
        call: http.get
        args:
          url: $${"https://dataform.googleapis.com/v1beta1/" + workflowInvocation.body.name}
          auth:
            type: OAuth2
        result: dataformStatus
    - switchStatus:
        switch:
          - condition: $${dataformStatus.body.state == "RUNNING" or dataformStatus.body.state == "CANCELING"}
            next: waitForDataform
          - condition: $${dataformStatus.body.state == "SUCCEEDED"}
            next: callExportScheduleFunction
          - condition: true
            return: $${"Dataform failed with state " + dataformStatus.body.state}
    - callExportScheduleFunction:
        call: http.post
        args:
          url: "${google_cloudfunctions2_function.export_schedules.service_config[0].uri}"
          timeout: 600
          auth:
            type: OIDC
        result: exportScheduleResult
    - callExportRacesFunction:
        call: http.post
        args:
          url: "${google_cloudfunctions2_function.export_races.service_config[0].uri}"
          timeout: 600
          auth:
            type: OIDC
        result: exportRacesResult
    - callExportRaceUmaDetailsFunction:
        call: http.post
        args:
          url: "${google_cloudfunctions2_function.export_race_uma_details.service_config[0].uri}"
          timeout: 1800
          auth:
            type: OIDC
        result: exportRaceUmaDetailsResult
    - returnResult:
        return:
          dataform: $${dataformStatus.body}
          exportSchedule: $${exportScheduleResult.body}
          exportRaces: $${exportRacesResult.body}
          exportRaceUmaDetails: $${exportRaceUmaDetailsResult.body}
EOF
}

resource "google_workflows_workflow" "dataform_trigger_workflow_prd" {
  count           = terraform.workspace == "prd" ? 1 : 0
  depends_on      = [google_project_service.workflows]
  name            = "dataform-trigger-workflow"
  region          = var.region
  description     = "BigQueryテーブル更新時にDataform実行をトリガーするワークフロー (Production)"
  service_account = google_service_account.workflows_sa.id
  project         = var.project_id

  source_contents = <<EOF
main:
  params: [args]
  steps:
    - init:
        assign:
          - repository: "projects/${var.project_id}/locations/${var.region}/repositories/${google_dataform_repository.repository_prd[0].name}"
          - workspace: "${var.dataform_workspace_id}"
    - createCompilationResult:
        call: http.post
        args:
          url: $${"https://dataform.googleapis.com/v1beta1/" + repository + "/compilationResults"}
          auth:
            type: OAuth2
          body:
            gitCommitish: "main"
            codeCompilationConfig:
              defaultDatabase: "${var.project_id}"
              defaultSchema: "${var.prd_schema}"
              vars:
                source_schema: "kolbi_keiba"
        result: compilationResult
    - createWorkflowInvocation:
        call: http.post
        args:
          url: $${"https://dataform.googleapis.com/v1beta1/" + repository + "/workflowInvocations"}
          auth:
            type: OAuth2
          body:
            compilationResult: $${compilationResult.body.name}
            invocationConfig:
              includedTags: $${default(map.get(args, "tags"), [])}
              serviceAccount: "dataform-runner@${var.project_id}.iam.gserviceaccount.com"
        result: workflowInvocation
    # Dataform完了待機
    - waitForDataform:
        call: sys.sleep
        args:
          seconds: 30
    - checkDataformStatus:
        call: http.get
        args:
          url: $${"https://dataform.googleapis.com/v1beta1/" + workflowInvocation.body.name}
          auth:
            type: OAuth2
        result: dataformStatus
    - switchStatus:
        switch:
          - condition: $${dataformStatus.body.state == "RUNNING" or dataformStatus.body.state == "CANCELING"}
            next: waitForDataform
          - condition: $${dataformStatus.body.state == "SUCCEEDED"}
            next: callExportScheduleFunction
          - condition: true
            return: $${"Dataform failed with state " + dataformStatus.body.state}
    - callExportScheduleFunction:
        call: http.post
        args:
          url: "${google_cloudfunctions2_function.export_schedules.service_config[0].uri}"
          timeout: 600
          auth:
            type: OIDC
        result: exportScheduleResult
    - callExportRacesFunction:
        call: http.post
        args:
          url: "${google_cloudfunctions2_function.export_races.service_config[0].uri}"
          timeout: 600
          auth:
            type: OIDC
        result: exportRacesResult
    - callExportRaceUmaDetailsFunction:
        call: http.post
        args:
          url: "${google_cloudfunctions2_function.export_race_uma_details.service_config[0].uri}"
          timeout: 1800
          auth:
            type: OIDC
        result: exportRaceUmaDetailsResult
    - returnResult:
        return:
          dataform: $${dataformStatus.body}
          exportSchedule: $${exportScheduleResult.body}
          exportRaces: $${exportRacesResult.body}
          exportRaceUmaDetails: $${exportRaceUmaDetailsResult.body}
EOF
}
