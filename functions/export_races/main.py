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

import sys

# ログ設定
logging.basicConfig(stream=sys.stdout, level=logging.INFO)
logger = logging.getLogger(__name__)

# 環境変数
PROJECT_ID = os.environ.get("PROJECT_ID")
DATASET_ID = os.environ.get("DATASET_ID") # 例: kolbi_analysis または kolbi_analysis_stg
SECRET_USER = os.environ.get("SECRET_USER") # ユーザー名のシークレットリソースID
SECRET_PASS = os.environ.get("SECRET_PASS") # パスワードのシークレットリソースID
STATE_TABLE_NAME = "races_export_state"
FTP_HOST = "smartkb.mixh.jp"
BUBBLE_API_URL = os.environ.get("BUBBLE_API_URL")
BUBBLE_API_KEY_SECRET_ID = os.environ.get("BUBBLE_API_KEY_SECRET_ID")
CSV_BASE_URL = os.environ.get("CSV_BASE_URL", "https://kol-bi.jp/umasiri.dev")
ENABLE_BUBBLE_API = str(os.environ.get("ENABLE_BUBBLE_API", "true")).lower() == "true"

def get_secret(secret_id):
    """Secret Managerからシークレット値を取得する"""
    client = secretmanager.SecretManagerServiceClient()
    name = f"{secret_id}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")

def ensure_state_table(bq_client, dataset_id, table_name):
    """状態管理テーブルが存在することを確認し、なければ作成する"""
    table_ref = f"{PROJECT_ID}.{dataset_id}.{table_name}"
    schema = [
        bigquery.SchemaField("race_code_kol", "STRING", mode="REQUIRED"),
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
    # 行の値を文字列に変換し、ハッシュ化のために連結する
    # ソートして順序を一貫させる
    row_str = json.dumps(dict(row), sort_keys=True, default=str)
    return hashlib.sha256(row_str.encode('utf-8')).hexdigest()

@functions_framework.http
def export_races(request):
    """更新されたレース情報をFTPにエクスポートするHTTP Cloud Function"""
    try:
        # 1. クライアントの初期化
        bq_client = bigquery.Client(project=PROJECT_ID)

        # 2. FTP認証情報の取得
        logger.info("FTP認証情報を取得中...")
        ftp_user = get_secret(SECRET_USER)
        ftp_pass = get_secret(SECRET_PASS)

        # 3. 状態管理テーブルの確認
        ensure_state_table(bq_client, DATASET_ID, STATE_TABLE_NAME)

        # 4. 更新のクエリ
        query = f"""
            WITH CurrentRaces AS (
                SELECT
                    *
                FROM `{PROJECT_ID}.{DATASET_ID}.race`
            ),
            State AS (
                SELECT
                    race_code_kol,
                    content_hash
                FROM `{PROJECT_ID}.{DATASET_ID}.{STATE_TABLE_NAME}`
            )
            SELECT
                c.*,
                s.content_hash as old_hash
            FROM CurrentRaces c
            LEFT JOIN State s ON c.race_code_kol = s.race_code_kol
            ORDER BY c.hasso_date
        """

        logger.info("BigQueryで変更をクエリ中...")
        query_job = bq_client.query(query)
        rows = list(query_job.result())

        updates = []
        state_updates = []

        # テーブルスキーマから出力用フィールドを自動取得
        table_ref = f"{PROJECT_ID}.{DATASET_ID}.race"
        table_info = bq_client.get_table(table_ref)
        fieldnames = [field.name for field in table_info.schema]

        for row in rows:
            row_data = {field: row[field] for field in fieldnames}

            # ハッシュ計算用データ（タイムスタンプは除外）
            hash_data = row_data.copy()
            for key in ["created", "modified"]:
                if key in hash_data:
                    del hash_data[key]

            current_hash = calculate_hash(hash_data)
            old_hash = row["old_hash"]

            if old_hash is None or current_hash != old_hash:
                updates.append(row_data)
                state_updates.append({
                    "race_code_kol": row_data["race_code_kol"],
                    "content_hash": current_hash
                })

        logger.info(f"{len(updates)} 件の更新が見つかりました。")

        if not updates:
            return "更新はありませんでした。", 200

        # 5. CSV生成とFTPアップロード
        CHUNK_SIZE = 1000
        table_name = "race"

        # hasso_date (YYYY/MM/DD HH:MM:SS) から YYYYMMDD を抽出してMin/Maxを取得
        all_dates = []
        for u in updates:
            # hasso_dateがdatetimeオブジェクトか文字列か確認が必要だが、BigQueryからは通常オブジェクトで返る
            # main.pyの修正前のコードを見ると文字列として扱っている箇所はないが、念のため型変換
            dt = u["hasso_date"]
            if isinstance(dt, str):
                 # 文字列の場合はパースが必要だが、フォーマットは YYYY/MM/DD HH:MM:SS
                 dt = datetime.datetime.strptime(dt, '%Y/%m/%d %H:%M:%S')

            all_dates.append(dt.strftime('%Y%m%d'))

        min_date = min(all_dates)
        max_date = max(all_dates)

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
                    chunk_dates = []
                    for u in chunk:
                        dt = u["hasso_date"]
                        if isinstance(dt, str):
                                dt = datetime.datetime.strptime(dt, '%Y/%m/%d %H:%M:%S')
                        chunk_dates.append(dt.strftime('%Y%m%d'))

                    chunk_min_date = min(chunk_dates)
                    chunk_max_date = max(chunk_dates)

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
                    writer = csv.DictWriter(csv_buffer, fieldnames=fieldnames)
                    writer.writeheader()
                    writer.writerows(chunk)
                    csv_content = csv_buffer.getvalue().encode('utf-8')

                    bio = io.BytesIO(csv_content)
                    ftp.storbinary(f"STOR {filename}", bio)
                    logger.info(f"{filename} のアップロードに成功しました。")

                    # Bubble APIへの通知
                    if ENABLE_BUBBLE_API and BUBBLE_API_URL and BUBBLE_API_KEY_SECRET_ID:
                        try:
                            if ftp_directory:
                                dir_path = ftp_directory.strip("/")
                                csv_url = f"{CSV_BASE_URL}/{dir_path}/{filename}"
                            else:
                                csv_url = f"{CSV_BASE_URL}/{filename}"

                            logger.info(f"通知対象CSV URL: {csv_url}")
                            api_key = get_secret(BUBBLE_API_KEY_SECRET_ID)
                            headers = {
                                "Content-Type": "application/json",
                                "Authorization": f"Bearer {api_key}"
                            }
                            payload = {
                                "csv_url": csv_url
                            }
                            logger.info(f"Bubble APIへリクエストを送信します: URL={BUBBLE_API_URL}")
                            response = requests.post(BUBBLE_API_URL, json=payload, headers=headers)
                            response.raise_for_status()

                            resp_json = response.json()
                            logger.info(f"Bubble APIへの通知に成功しました ({filename}): {resp_json}")

                            # インポート成功可否のチェック
                            if resp_json.get("response", {}).get("is_import_success") is False:
                                error_text = resp_json.get("response", {}).get("error_text", "Unknown error")
                                logger.error(f"Bubble Import Failed ({filename}): {error_text}")
                                raise Exception(f"Bubble Import Failed: {error_text}")

                        except Exception as e:
                            logger.error(f"Bubble APIへの通知に失敗しました ({filename}): {e}")
                            # ワークフローを停止させるため例外を再送出する
                            raise e
                    else:
                        if i == 0: # ログ過多防止のため初回のみログ出力
                             if not ENABLE_BUBBLE_API:
                                  logger.info("ENABLE_BUBBLE_APIがfalseのため、通知をスキップします。")
                             else:
                                  logger.info("Bubble API設定がされていないため、通知をスキップします。")

        except Exception as e:
            logger.error(f"FTPアップロードに失敗しました: {e}")
            return f"FTPアップロード失敗: {e}", 500

        # 7. 状態管理テーブルの更新
        logger.info("状態管理テーブルを更新中...")
        if state_updates:
            # MERGEを使用して状態をUPSERT

            # 挿入用データの準備
            rows_to_insert = [
                {
                    "race_code_kol": u["race_code_kol"],
                    "content_hash": u["content_hash"],
                    "exported_at": datetime.datetime.now().isoformat()
                }
                for u in state_updates
            ]

            # 1. 一時テーブルへのロード
            job_config = bigquery.LoadJobConfig(
                write_disposition="WRITE_TRUNCATE",
                schema=[
                    bigquery.SchemaField("race_code_kol", "STRING"),
                    bigquery.SchemaField("content_hash", "STRING"),
                    bigquery.SchemaField("exported_at", "TIMESTAMP"),
                ]
            )
            temp_table_id = f"{PROJECT_ID}.{DATASET_ID}.temp_races_state_updates"
            load_job = bq_client.load_table_from_json(rows_to_insert, temp_table_id, job_config=job_config)
            load_job.result() # 待機

            # 2. マージ実行
            merge_query = f"""
                MERGE `{PROJECT_ID}.{DATASET_ID}.{STATE_TABLE_NAME}` T
                USING `{temp_table_id}` S
                ON T.race_code_kol = S.race_code_kol
                WHEN MATCHED THEN
                  UPDATE SET content_hash = S.content_hash, exported_at = S.exported_at
                WHEN NOT MATCHED THEN
                  INSERT (race_code_kol, content_hash, exported_at)
                  VALUES (race_code_kol, content_hash, exported_at)
            """

            bq_client.query(merge_query).result()
            logger.info("状態管理テーブルが更新されました。")

            # 一時テーブルの削除
            bq_client.delete_table(temp_table_id, not_found_ok=True)

        return f"成功。 {len(updates)} 行をエクスポートしました。", 200

    except Exception as e:
        logger.exception("実行中にエラーが発生しました。")
        return f"内部サーバーエラー: {e}", 500
