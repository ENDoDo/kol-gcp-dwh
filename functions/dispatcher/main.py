
import os
import json
import logging
import datetime
import functions_framework
from google.cloud import tasks_v2
from google.protobuf import timestamp_pb2
from google.api_core.exceptions import AlreadyExists

# ログ設定
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# 環境変数
PROJECT_ID = os.environ.get("PROJECT_ID")
REGION = os.environ.get("REGION")
QUEUE_NAME = os.environ.get("QUEUE_NAME") # e.g. "dataform-trigger-queue"
WORKFLOW_NAME = os.environ.get("WORKFLOW_NAME") # e.g. "dataform-trigger-workflow"
DEBOUNCE_SECONDS = int(os.environ.get("DEBOUNCE_SECONDS", 300)) # デフォルト5分
WORKFLOW_SERVICE_ACCOUNT_EMAIL = os.environ.get("WORKFLOW_SERVICE_ACCOUNT_EMAIL")

@functions_framework.http
def dispatch_workflow(request):
    """
    Eventarcからのリクエストを受け取り、Cloud Tasksにタスクを作成してデバウンスを行う。
    """
    try:
        data = request.get_json(silent=True)
        # Eventarcからのデータ (必要に応じて解析)
        # BQのLoadイベントなどが入ってくるが、今回はトリガー自体が目的なので詳細は問わない

        client = tasks_v2.CloudTasksClient()

        # Cloud Tasksの完全パス
        parent = client.queue_path(PROJECT_ID, REGION, QUEUE_NAME)

        # ワークフロー実行APIのURL
        workflow_url = f"https://workflowexecutions.googleapis.com/v1/projects/{PROJECT_ID}/locations/{REGION}/workflows/{WORKFLOW_NAME}/executions"

        # タスクの設定
        task_id = "dataform-trigger-debounce-task" # 固定IDにすることで重複排除
        task_name = client.task_path(PROJECT_ID, REGION, QUEUE_NAME, task_id)

        # 実行時刻の設定 (現在時刻 + DEBOUNCE_SECONDS)
        d = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=DEBOUNCE_SECONDS)
        timestamp = timestamp_pb2.Timestamp()
        timestamp.FromDatetime(d)

        task = {
            "name": task_name,
            "http_request": {
                "http_method": tasks_v2.HttpMethod.POST,
                "url": workflow_url,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"argument": "{}"}).encode(),
                # OIDCトークン設定 (Workflowsの実行権限を持つSAを指定)
                "oidc_token": {
                    "service_account_email": WORKFLOW_SERVICE_ACCOUNT_EMAIL,
                },
            },
            "schedule_time": timestamp
        }

        logger.info(f"タスク作成を試みます: {task_name}, Schedule: {d}")

        try:
            response = client.create_task(request={"parent": parent, "task": task})
            logger.info(f"タスクを作成しました: {response.name}")
            return "Debounce task created", 200
        except AlreadyExists:
            logger.info(f"タスクは既に存在します (Debounced): {task_name}")
            return "Event debounced", 200

    except Exception as e:
        logger.exception("Dispatcher実行中にエラーが発生しました")
        return f"Internal Server Error: {e}", 500
