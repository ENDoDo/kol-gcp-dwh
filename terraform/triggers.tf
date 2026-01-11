# -----------------------------------------------------------------------------
# Dataformワークフロー用トリガー設定
# -----------------------------------------------------------------------------

# --- Pub/Sub トピック ---
resource "google_pubsub_topic" "dataform_trigger_topic" {
  name    = "dataform-trigger-topic${local.env_suffix}"
  project = var.project_id
}

# --- Logging Sink ---
# 宛先テーブルが kol_den1 であるBigQueryジョブ完了イベントをフィルタリング
resource "google_logging_project_sink" "bq_update_sink" {
  name        = "bq-kol-den1-update-sink${local.env_suffix}"
  destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${google_pubsub_topic.dataform_trigger_topic.name}"
  filter      = <<EOT
resource.type="bigquery_resource"
protoPayload.methodName="jobservice.jobcompleted"
(
  (
    protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.load.destinationTable.datasetId="${local.dataform_source_schema}"
    protoPayload.serviceData.jobCompletedEvent.job.jobStatistics.totalLoadOutputBytes > 0
    (
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.load.destinationTable.tableId="kol_den1" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.load.destinationTable.tableId="kol_den2" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.load.destinationTable.tableId="kol_ket" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.load.destinationTable.tableId="kol_sei1" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.load.destinationTable.tableId="kol_sei2"
    )
  )
  OR
  (
    protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.query.destinationTable.datasetId="${local.dataform_source_schema}"
    (
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.query.destinationTable.tableId="kol_den1" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.query.destinationTable.tableId="kol_den2" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.query.destinationTable.tableId="kol_ket" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.query.destinationTable.tableId="kol_sei1" OR
      protoPayload.serviceData.jobCompletedEvent.job.jobConfiguration.query.destinationTable.tableId="kol_sei2"
    )
  )
)
EOT

  unique_writer_identity = true
  project                = var.project_id
}

# Logging SinkのIDにPub/Sub Publisherロールを付与
resource "google_pubsub_topic_iam_member" "sink_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dataform_trigger_topic.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.bq_update_sink.writer_identity
}

# --- Eventarc トリガー ---
# Pub/SubトピックにメッセージがパブリッシュされたときにCloud Workflowをトリガー
resource "google_eventarc_trigger" "workflow_trigger" {
  name     = "dataform-workflow-trigger${local.env_suffix}"
  location = var.region
  project  = var.project_id
  service_account = google_service_account.workflows_sa.email # Workflows用SAまたは専用SAを使用

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.dataform_trigger_topic.id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloudfunctions2_function.dispatcher_function.name
      region  = var.region
    }
  }

  depends_on = [
    google_cloudfunctions2_function.dispatcher_function
  ]
}

# EventarcがWorkflowsを呼び出すための権限付与
# トリガーIDには workflows.invoker が必要です。
# ここでは簡単のため workflows_sa をトリガーIDとして再利用していますが、ワークフローを呼び出す権限があることを確認します。
resource "google_project_iam_member" "workflows_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.workflows_sa.email}"
}
