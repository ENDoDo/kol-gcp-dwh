import os
import hashlib
import csv
import io
import json
import logging
import ftplib
import functions_framework
from google.cloud import bigquery
from google.cloud import secretmanager
import datetime
import requests
from flask import Response, stream_with_context

import sys

# ログ設定
logging.basicConfig(stream=sys.stdout, level=logging.INFO)
logger = logging.getLogger(__name__)

# 環境変数
PROJECT_ID = os.environ.get("PROJECT_ID")
DATASET_ID = os.environ.get("DATASET_ID") # 例: kolbi_analysis または kolbi_analysis_stg
SECRET_USER = os.environ.get("SECRET_USER") # ユーザー名のシークレットリソースID
SECRET_PASS = os.environ.get("SECRET_PASS") # パスワードのシークレットリソースID
STATE_TABLE_NAME = "schedules_export_state"
FTP_HOST = "smartkb.mixh.jp"
BUBBLE_API_URL = os.environ.get("BUBBLE_API_URL")
BUBBLE_API_URL_SECRET_ID = os.environ.get("BUBBLE_API_URL_SECRET_ID")
BUBBLE_API_KEY_SECRET_ID = os.environ.get("BUBBLE_API_KEY_SECRET_ID")
CSV_BASE_URL = os.environ.get("CSV_BASE_URL", "https://kol-bi.jp/umasiri.dev")
ENABLE_BUBBLE_API = str(os.environ.get("ENABLE_BUBBLE_API", "false")).lower() == "true"
ENABLE_BUBBLE_API_SECRET_ID = os.environ.get("ENABLE_BUBBLE_API_SECRET_ID")

def get_secret(secret_id):
    """Secret Managerからシークレット値を取得する"""
    client = secretmanager.SecretManagerServiceClient()
    name = f"{secret_id}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")

def get_bubble_api_url(request_override=None):
    """優先度: リクエストパラメータ > Secret Manager > env var"""
    if request_override:
        return request_override
    if BUBBLE_API_URL_SECRET_ID:
        try:
            return get_secret(BUBBLE_API_URL_SECRET_ID)
        except Exception as e:
            logger.warning(f"Secret ManagerからのURL取得に失敗、env varにフォールバック: {e}")
    return BUBBLE_API_URL

def get_enable_bubble_api():
    """優先度: Secret Manager > env var フォールバック（失敗時は false）"""
    if ENABLE_BUBBLE_API_SECRET_ID:
        try:
            val = get_secret(ENABLE_BUBBLE_API_SECRET_ID)
            return val.strip().lower() == "true"
        except Exception as e:
            logger.warning(f"Secret ManagerからのENABLE_BUBBLE_API取得失敗、env varにフォールバック: {e}")
    return ENABLE_BUBBLE_API

def ensure_state_table(bq_client, dataset_id, table_name):
    """状態管理テーブルが存在することを確認し、なければ作成する"""
    table_ref = f"{PROJECT_ID}.{dataset_id}.{table_name}"
    schema = [
        bigquery.SchemaField("schedule_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("content_hash", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("exported_at", "TIMESTAMP", mode="REQUIRED"),
    ]
    try:
        bq_client.get_table(table_ref)
        logger.info(f"テーブル {table_ref} は既に存在します。")
    except Exception:
        logger.info(f"テーブル {table_ref} を作成しています...")
        table = bigquery.Table(table_ref, schema=schema)
        bq_client.create_table(table)
        logger.info(f"テーブル {table_ref} を作成しました。")

def calculate_hash(row):
    """行の内容のハッシュを計算し、変更を検知する"""
    row_str = json.dumps(dict(row), sort_keys=True, default=str)
    return hashlib.sha256(row_str.encode('utf-8')).hexdigest()

@functions_framework.http
def export_schedules(request):
    """更新されたスケジュールをFTPにエクスポートするHTTP Cloud Function"""
    try:
        # 1. クライアントの初期化
        bq_client = bigquery.Client(project=PROJECT_ID)

        # 2. FTP認証情報の取得
        logger.info("FTP認証情報を取得中...")
        ftp_user = get_secret(SECRET_USER)
        ftp_pass = get_secret(SECRET_PASS)

        # 3. 状態管理テーブルの確認
        ensure_state_table(bq_client, DATASET_ID, STATE_TABLE_NAME)

        # リクエストパラメータ解析
        request_json = request.get_json(silent=True) or {}
        from_date      = request_json.get("from_date")
        to_date        = request_json.get("to_date")
        force_resend   = request_json.get("force_resend", False)
        bubble_api_url = get_bubble_api_url(request_json.get("bubble_api_url"))
        enable_bubble  = force_resend or get_enable_bubble_api()

        # force_resend モード: 日付範囲指定 + 差分検知スキップ + SSE ストリーム
        if force_resend and from_date and to_date:
            date_params = [
                bigquery.ScalarQueryParameter("from_date", "DATE", from_date),
                bigquery.ScalarQueryParameter("to_date",   "DATE", to_date),
            ]
            count_job = bq_client.query(
                f"SELECT COUNT(*) AS total FROM `{PROJECT_ID}.{DATASET_ID}.schedule` WHERE DATE(period1_start) BETWEEN @from_date AND @to_date",
                job_config=bigquery.QueryJobConfig(query_parameters=date_params)
            )
            total = list(count_job.result())[0].total

            data_job = bq_client.query(
                f"SELECT * FROM `{PROJECT_ID}.{DATASET_ID}.schedule` WHERE DATE(period1_start) BETWEEN @from_date AND @to_date ORDER BY period1_start",
                job_config=bigquery.QueryJobConfig(query_parameters=date_params)
            )
            rows_result = list(data_job.result())

            if not rows_result:
                return "更新はありませんでした。", 200

            table_info_fr = bq_client.get_table(f"{PROJECT_ID}.{DATASET_ID}.schedule")
            fn = [field.name for field in table_info_fr.schema]
            all_data = [{f: row[f] for f in fn} for row in rows_result]
            chunks_fr = [all_data[i:i+1000] for i in range(0, len(all_data), 1000)]
            total_parts_fr = len(chunks_fr)
            ftp_dir = os.environ.get("FTP_DIRECTORY")

            def generate_sse():
                state_upd = []
                processed = 0
                try:
                    with ftplib.FTP(FTP_HOST) as ftp:
                        ftp.login(user=ftp_user, passwd=ftp_pass)
                        if ftp_dir:
                            try:
                                ftp.cwd(ftp_dir)
                            except ftplib.error_perm as e:
                                logger.warning(f"ディレクトリ {ftp_dir} への移動に失敗: {e}")

                        for i, chunk in enumerate(chunks_fr):
                            for row_data in chunk:
                                hash_data = {k: v for k, v in row_data.items() if k not in ("created", "modified")}
                                state_upd.append({
                                    "schedule_id": row_data["id"],
                                    "content_hash": calculate_hash(hash_data)
                                })

                            chunk_ids = [r["id"] for r in chunk]
                            c_min, c_max = min(chunk_ids), max(chunk_ids)
                            filename = f"schedule_{c_min}_{c_max}_part{i+1:03d}.csv" if total_parts_fr > 1 else f"schedule_{c_min}_{c_max}.csv"

                            csv_buf = io.StringIO()
                            writer = csv.DictWriter(csv_buf, fieldnames=fn)
                            writer.writeheader()
                            writer.writerows(chunk)
                            ftp.storbinary(f"STOR {filename}", io.BytesIO(csv_buf.getvalue().encode("utf-8")))
                            logger.info(f"{filename} のアップロード完了")

                            if enable_bubble and bubble_api_url and BUBBLE_API_KEY_SECRET_ID:
                                dir_path = ftp_dir.strip("/") if ftp_dir else None
                                csv_url = f"{CSV_BASE_URL}/{dir_path}/{filename}" if dir_path else f"{CSV_BASE_URL}/{filename}"
                                api_key = get_secret(BUBBLE_API_KEY_SECRET_ID)
                                resp = requests.post(
                                    bubble_api_url,
                                    json={"csv_url": csv_url},
                                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}
                                )
                                resp_json = None
                                try:
                                    resp_json = resp.json()
                                except Exception:
                                    pass
                                if not resp.ok:
                                    if resp_json and "message" in resp_json:
                                        raise Exception(f"Bubble API Error ({resp.status_code}): {resp_json['message']}")
                                    resp.raise_for_status()
                                if resp_json:
                                    resp_data = resp_json.get("response", {})
                                    is_success = resp_data.get("is_import_success")
                                    if is_success is None:
                                        is_success = resp_data.get("is import success")
                                    if is_success is False:
                                        error_text = resp_data.get("error_text") or resp_data.get("error text", "Unknown error")
                                        if "短時間で同じファイルの取り込みを検知したため中止" in error_text:
                                            logger.warning(f"Bubble API Warning (Duplicate): {error_text}")
                                        else:
                                            raise Exception(f"Bubble Import Failed: {error_text}")

                            processed += len(chunk)
                            current_date = str(max(r["period1_start"] for r in chunk))[:10]
                            pct = int(processed / total * 100) if total > 0 else 100
                            yield f"event: progress\ndata: {json.dumps({'current_date': current_date, 'processed': processed, 'total': total, 'pct': pct})}\n\n"

                    if state_upd:
                        rows_to_insert = [
                            {
                                "schedule_id": u["schedule_id"],
                                "content_hash": u["content_hash"],
                                "exported_at": datetime.datetime.now().isoformat()
                            }
                            for u in state_upd
                        ]
                        temp_table_id = f"{PROJECT_ID}.{DATASET_ID}.temp_schedules_state_updates"
                        load_job = bq_client.load_table_from_json(
                            rows_to_insert, temp_table_id,
                            job_config=bigquery.LoadJobConfig(
                                write_disposition="WRITE_TRUNCATE",
                                schema=[
                                    bigquery.SchemaField("schedule_id", "STRING"),
                                    bigquery.SchemaField("content_hash", "STRING"),
                                    bigquery.SchemaField("exported_at", "TIMESTAMP"),
                                ]
                            )
                        )
                        load_job.result()
                        bq_client.query(f"""
                            MERGE `{PROJECT_ID}.{DATASET_ID}.{STATE_TABLE_NAME}` T
                            USING `{temp_table_id}` S
                            ON T.schedule_id = S.schedule_id
                            WHEN MATCHED THEN
                              UPDATE SET content_hash = S.content_hash, exported_at = S.exported_at
                            WHEN NOT MATCHED THEN
                              INSERT (schedule_id, content_hash, exported_at)
                              VALUES (schedule_id, content_hash, exported_at)
                        """).result()
                        bq_client.delete_table(temp_table_id, not_found_ok=True)
                        logger.info("状態管理テーブルが更新されました。")

                    yield f"event: result\ndata: {json.dumps({'status': 'success', 'records': processed})}\n\n"

                except Exception as e:
                    logger.exception("force_resend 処理中にエラー")
                    yield f"event: result\ndata: {json.dumps({'status': 'error', 'message': str(e)})}\n\n"

            return Response(
                stream_with_context(generate_sse()),
                mimetype="text/event-stream",
                headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"},
            )

        # 4. 更新のクエリ
        # ロジック:
        # - 現在の全てのスケジュールを取得
        # - 状態管理テーブルと左外部結合
        # - 状態がNULL（新規）またはハッシュが異なる（更新）行をフィルタリング

        query = f"""
            WITH CurrentSchedules AS (
                SELECT
                    *
                FROM `{PROJECT_ID}.{DATASET_ID}.schedule`
            ),
            State AS (
                SELECT
                    schedule_id,
                    content_hash
                FROM `{PROJECT_ID}.{DATASET_ID}.{STATE_TABLE_NAME}`
            )
            SELECT
                c.*,
                s.content_hash as old_hash
            FROM CurrentSchedules c
            LEFT JOIN State s ON c.id = s.schedule_id
            ORDER BY c.id
        """

        logger.info("BigQueryで変更をクエリ中...")
        query_job = bq_client.query(query)
        rows = list(query_job.result())

        updates = []
        state_updates = []

        # テーブルスキーマから出力用フィールドを自動取得
        table_ref = f"{PROJECT_ID}.{DATASET_ID}.schedule"
        table_info = bq_client.get_table(table_ref)
        fieldnames = [field.name for field in table_info.schema]

        for row in rows:
            # 行データを辞書として再構築
            row_data = {field: row[field] for field in fieldnames}

            # ハッシュ計算用データ（タイムスタンプは毎回変わるため除外）
            hash_data = row_data.copy()
            for key in ["created", "modified"]:
                if key in hash_data:
                    del hash_data[key]

            current_hash = calculate_hash(hash_data)
            old_hash = row["old_hash"]

            if old_hash is None or current_hash != old_hash:
                updates.append(row_data)
                state_updates.append({
                    "schedule_id": row_data["id"],
                    "content_hash": current_hash
                })

        logger.info(f"{len(updates)} 件の更新が見つかりました。")

        if not updates:
            return "更新はありませんでした。", 200

        # 5. CSV生成とFTPアップロード
        CHUNK_SIZE = 1000
        table_name = "schedule"

        # 更新データ(updates)からMin/Maxの日付(id)を取得
        # updates内のidはYYYYMMDD形式であることを前提とする
        all_ids = [u["id"] for u in updates]
        min_date = min(all_ids)
        max_date = max(all_ids)

        # データをチャンクに分割
        chunks = [updates[i:i + CHUNK_SIZE] for i in range(0, len(updates), CHUNK_SIZE)]
        total_parts = len(chunks)

        logger.info(f"FTPホスト {FTP_HOST} へアップロード中... (合計 {len(updates)} 件 - {total_parts} ファイル)")

        try:
            with ftplib.FTP(FTP_HOST) as ftp:
                ftp.login(user=ftp_user, passwd=ftp_pass)

                # ディレクトリ移動
                ftp_directory = os.environ.get("FTP_DIRECTORY")
                if ftp_directory:
                    try:
                        ftp.cwd(ftp_directory)
                        logger.info(f"FTPディレクトリを {ftp_directory} に変更しました。")
                    except ftplib.error_perm as e:
                        logger.warning(f"ディレクトリ {ftp_directory} への移動に失敗しました: {e}。ルートディレクトリを使用します。")

                for i, chunk in enumerate(chunks):
                    # チャンクごとの日付範囲を取得
                    chunk_ids = [u["id"] for u in chunk]
                    chunk_min_date = min(chunk_ids)
                    chunk_max_date = max(chunk_ids)

                    # ファイル名の生成
                    if total_parts > 1:
                        # 分割あり: {table_name}_{from}_{to}_part{NNN}.csv
                        part_num = i + 1
                        filename = f"{table_name}_{chunk_min_date}_{chunk_max_date}_part{part_num:03d}.csv"
                    else:
                        # 分割なし: {table_name}_{from}_{to}.csv
                        filename = f"{table_name}_{chunk_min_date}_{chunk_max_date}.csv"

                    logger.info(f"CSVを生成中... ({filename})")
                    csv_buffer = io.StringIO()
                    # 動的に取得したfieldnamesを使用
                    # fieldnames = ["id", "year", "month_day", "period1_start", "period1_start_utc", "period2_end", "period2_end_utc", "main_race_names", "keibajo_names", "modified", "created"]
                    writer = csv.DictWriter(csv_buffer, fieldnames=fieldnames)
                    writer.writeheader()
                    writer.writerows(chunk)
                    csv_content = csv_buffer.getvalue().encode('utf-8')

                    bio = io.BytesIO(csv_content)
                    ftp.storbinary(f"STOR {filename}", bio)
                    logger.info(f"{filename} のアップロードに成功しました。")

        except Exception as e:
            logger.error(f"FTPアップロードに失敗しました: {e}")
            return f"FTPアップロード失敗: {e}", 500

        # 6. Bubble APIへの通知
        if enable_bubble and bubble_api_url and BUBBLE_API_KEY_SECRET_ID:
            try:
                logger.info("Bubble APIへの通知を開始します...")
                api_key = get_secret(BUBBLE_API_KEY_SECRET_ID)

                ftp_directory = os.environ.get("FTP_DIRECTORY")
                if ftp_directory:
                    dir_path = ftp_directory.strip("/")
                    csv_url = f"{CSV_BASE_URL}/{dir_path}/{filename}"
                else:
                    csv_url = f"{CSV_BASE_URL}/{filename}"

                logger.info(f"通知対象CSV URL: {csv_url}")

                headers = {
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}"
                }
                payload = {
                    "csv_url": csv_url
                }

                logger.info(f"Bubble APIへリクエストを送信します: URL={bubble_api_url}")
                response = requests.post(bubble_api_url, json=payload, headers=headers)

                # エラーレスポンスでもJSONが含まれている可能性があるため、まずデコードを試みる
                resp_json = None
                try:
                    resp_json = response.json()
                except Exception:
                    pass

                if not response.ok:
                    # HTTP 4xx/5xx の場合
                    if resp_json and "message" in resp_json:
                        error_msg = f"Bubble API Error ({response.status_code}): {resp_json['message']}"
                        logger.error(error_msg)
                        raise Exception(error_msg)
                    else:
                        response.raise_for_status()

                logger.info(f"Bubble APIへの通知に成功しました: {resp_json}")

                # インポート成功可否のチェック (HTTP 200 OK だが内部でエラーの場合)
                if resp_json:
                    # キーの表記ゆれを考慮
                    resp_data = resp_json.get("response", {})
                    is_success = resp_data.get("is_import_success")
                    if is_success is None:
                        is_success = resp_data.get("is import success")

                    if is_success is False:
                        # エラー内容の取得
                        error_text = resp_data.get("error_text")
                        if error_text is None:
                            error_text = resp_data.get("error text", "Unknown error")

                        # 特例処理: 短時間重複エラーの場合は警告ログのみ
                        if "短時間で同じファイルの取り込みを検知したため中止" in error_text:
                            logger.warning(f"Bubble API Warning (Duplicate): {error_text}")
                        else:
                            logger.error(f"Bubble Import Failed: {error_text}")
                            raise Exception(f"Bubble Import Failed: {error_text}")

            except Exception as e:
                logger.error(f"Bubble APIへの通知に失敗しました: {e}")
                # ワークフローを停止させるため例外を再送出する
                raise e
        else:
            if not enable_bubble:
                 logger.info("ENABLE_BUBBLE_APIがfalseのため、通知をスキップします。")
            else:
                 logger.info("Bubble API設定がされていないため、通知をスキップします。")

        # 7. 状態管理テーブルの更新
        logger.info("状態管理テーブルを更新中...")
        if state_updates:
            # MERGEを使用して状態をUPSERT

            # 挿入用データの準備
            rows_to_insert = [
                {
                    "schedule_id": u["schedule_id"],
                    "content_hash": u["content_hash"],
                    "exported_at": datetime.datetime.now().isoformat()
                }
                for u in state_updates
            ]

            # 1. 一時テーブルへのロード
            job_config = bigquery.LoadJobConfig(
                write_disposition="WRITE_TRUNCATE",
                schema=[
                    bigquery.SchemaField("schedule_id", "STRING"),
                    bigquery.SchemaField("content_hash", "STRING"),
                    bigquery.SchemaField("exported_at", "TIMESTAMP"),
                ]
            )
            temp_table_id = f"{PROJECT_ID}.{DATASET_ID}.temp_schedules_state_updates"
            load_job = bq_client.load_table_from_json(rows_to_insert, temp_table_id, job_config=job_config)
            load_job.result() # 待機

            # 2. マージ実行
            merge_query = f"""
                MERGE `{PROJECT_ID}.{DATASET_ID}.{STATE_TABLE_NAME}` T
                USING `{temp_table_id}` S
                ON T.schedule_id = S.schedule_id
                WHEN MATCHED THEN
                  UPDATE SET content_hash = S.content_hash, exported_at = S.exported_at
                WHEN NOT MATCHED THEN
                  INSERT (schedule_id, content_hash, exported_at)
                  VALUES (schedule_id, content_hash, exported_at)
            """
            bq_client.query(merge_query).result()
            logger.info("状態管理テーブルが更新されました。")

            # 一時テーブルの削除
            bq_client.delete_table(temp_table_id, not_found_ok=True)

        return f"成功。 {len(updates)} 行をエクスポートしました。", 200

    except Exception as e:
        logger.exception("実行中にエラーが発生しました。")
        return f"内部サーバーエラー: {e}", 500
