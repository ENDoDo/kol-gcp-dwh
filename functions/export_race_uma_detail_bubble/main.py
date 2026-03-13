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
STATE_TABLE_NAME = "race_uma_detail_bubble_export_state"
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
        bigquery.SchemaField("race_code_uma_kol", "STRING", mode="REQUIRED"),
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


@functions_framework.http
def export_race_uma_detail_bubble(request):
    """更新されたレース詳細情報(race_uma_detail_bubble)をBubbleにエクスポートするHTTP Cloud Function"""
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
        # BigQuery側でハッシュ計算と差分抽出を行い、Python側のメモリ負荷を軽減する
        # created, modified は更新のたびに変わるため、ハッシュ計算から除外する
        query = f"""
            WITH SourceWithHash AS (
                SELECT
                    *,
                    TO_HEX(MD5(TO_JSON_STRING(
                        (SELECT AS STRUCT * EXCEPT(
                            created, modified,
                            shirushi_hanro_4f_flag, shirushi_hanro_1f_flag, shirushi_wood_4f_flag, shirushi_wood_1f_flag,
                            shirushi_awase_senchaku_flag, shirushi_point, shirushi_kubun_yosou_tansho_ninkijun, shirushi_kubun_rank,
                            shirushi_shirushi_label, shirushi_shirushi_num, torikeshi_tosu_num, toroku_tosu_num,
                            yosou_tansho_ninkijun_num,
                            yosou_tansho_odds_float
                        ) FROM UNNEST([t]))
                    ))) as current_hash
                FROM `{PROJECT_ID}.{DATASET_ID}.race_uma_detail_bubble` t
            ),
            State AS (
                SELECT
                    race_code_uma_kol,
                    content_hash
                FROM `{PROJECT_ID}.{DATASET_ID}.{STATE_TABLE_NAME}`
            )
            SELECT
                s.*
            FROM SourceWithHash s
            LEFT JOIN State st ON s.race_code_uma_kol = st.race_code_uma_kol
            WHERE
                st.content_hash IS NULL
                OR st.content_hash != s.current_hash
            ORDER BY s.hasso_date
        """

        logger.info("BigQueryで変更をクエリ中(SQL側でハッシュ計算)...")
        query_job = bq_client.query(query)
        # iteratorを取得（list()で全件取得しない）
        rows_iterator = query_job.result()

        updates_chunk = []
        state_updates = {}
        CHUNK_SIZE = 1000
        part_num = 1

        # テーブルスキーマから出力用フィールドを自動取得
        table_ref = f"{PROJECT_ID}.{DATASET_ID}.race_uma_detail_bubble"
        table_info = bq_client.get_table(table_ref)
        fieldnames = [field.name for field in table_info.schema]

        def upload_chunk(ftp_conn, chunk, current_part_num):
            """チャンクデータをFTPにアップロードする内部関数"""
            if not chunk:
                return

            # 日付範囲の特定
            chunk_dates = []
            for item in chunk:
                dt = item["hasso_date"]
                if isinstance(dt, str):
                     dt = datetime.datetime.strptime(dt, '%Y/%m/%d %H:%M:%S')
                elif isinstance(dt, datetime.date):
                     dt = datetime.datetime(dt.year, dt.month, dt.day)
                chunk_dates.append(dt.strftime('%Y%m%d'))

            c_min = min(chunk_dates)
            c_max = max(chunk_dates)
            table_name = "race_uma_detail_bubble"
            filename = f"{table_name}_{c_min}_{c_max}_part{current_part_num:03d}.csv"

            logger.info(f"FTPへアップロード中... ({filename}, {len(chunk)} rows)")
            try:
                # FTP接続は外部から渡される ftp_conn を使用する

                csv_buffer = io.StringIO()
                writer = csv.DictWriter(csv_buffer, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(chunk)

                # ディレクトリは事前に移動済みと仮定

                csv_content = csv_buffer.getvalue().encode('utf-8')
                bio = io.BytesIO(csv_content)
                ftp_conn.storbinary(f"STOR {filename}", bio)
                logger.info(f"{filename} のアップロード完了")

                # Bubble APIへの通知
                if ENABLE_BUBBLE_API and BUBBLE_API_URL and BUBBLE_API_KEY_SECRET_ID:
                    ftp_directory = os.environ.get("FTP_DIRECTORY")
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
                    try:
                        logger.info(f"Bubble APIへリクエストを送信します: URL={BUBBLE_API_URL}")
                        response = requests.post(BUBBLE_API_URL, json=payload, headers=headers)

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

                        logger.info(f"Bubble APIへの通知に成功しました ({filename}): {resp_json}")

                        # インポート成功可否のチェック (HTTP 200 OK だが内部でエラーの場合)
                        if resp_json and resp_json.get("response", {}).get("is_import_success") is False:
                            error_text = resp_json.get("response", {}).get("error_text", "Unknown error")
                            logger.error(f"Bubble Import Failed ({filename}): {error_text}")
                            raise Exception(f"Bubble Import Failed: {error_text}")

                    except Exception as e:
                        logger.error(f"Bubble APIへの通知に失敗しました ({filename}): {e}")
                        # ワークフローを停止させるため例外を再送出する
                        raise e
                else:
                    if current_part_num == 1: # ログ過多防止のため初回のみログ出力
                        if not ENABLE_BUBBLE_API:
                             logger.info("ENABLE_BUBBLE_APIがfalseのため、通知をスキップします。")
                        else:
                             logger.info("Bubble API設定がされていないため、通知をスキップします。")
            except Exception as e:
                logger.error(f"FTPアップロードエラー: {filename}, {e}")
                # 再送ロジックを入れるか、ここではエラーとして処理を継続するか
                # 今回はログを出して再送せず、例外を送出して止める
                raise e

        processed_count = 0

        # FTP接続の再利用
        logger.info(f"FTP接続を開始します: {FTP_HOST}")
        with ftplib.FTP(FTP_HOST) as ftp_conn:
            ftp_conn.login(user=ftp_user, passwd=ftp_pass)

            # ディレクトリ移動確認 (接続直後に1回だけ実行)
            ftp_directory = os.environ.get("FTP_DIRECTORY")
            if ftp_directory:
                try:
                    ftp_conn.cwd(ftp_directory)
                except ftplib.error_perm:
                    logger.info(f"ディレクトリ {ftp_directory} が存在しないため作成します。")
                    ftp_conn.mkd(ftp_directory)
                    ftp_conn.cwd(ftp_directory)

            # イテレータを回してストリーミング処理
            for row in rows_iterator:
                # Rowデータを辞書化
                row_data = {field: row[field] for field in fieldnames}

                # ハッシュ
                current_hash = row["current_hash"]

                # バッファに追加
                updates_chunk.append(row_data)
                # 状態更新用 (上書きして重複排除)
                state_updates[row_data["race_code_uma_kol"]] = {
                    "race_code_uma_kol": row_data["race_code_uma_kol"],
                    "content_hash": current_hash
                }

                # チャンクサイズに達したらアップロード
                if len(updates_chunk) >= CHUNK_SIZE:
                    upload_chunk(ftp_conn, updates_chunk, part_num)
                    processed_count += len(updates_chunk)
                    updates_chunk = [] # バッファクリア
                    part_num += 1

            # 残りのチャンクがあればアップロード
            if updates_chunk:
                upload_chunk(ftp_conn, updates_chunk, part_num)
                processed_count += len(updates_chunk)

        logger.info(f"合計 {processed_count} 件をエクスポートしました。")

        if processed_count == 0:
             logger.info("更新対象のレコードはありませんでした。")
             return "更新はありませんでした。", 200

        # 7. 状態管理テーブルの更新 (state_updatesはメモリに残っている前提)
        # 数十万件の場合はここでもメモリ不足になる可能性があるため、state_updatesもチャンク分割して一時テーブルにロード推奨だが
        # まずは8GBメモリを信じて一括ロードを試みる
        logger.info(f"状態管理テーブルを更新中... ({len(state_updates)} updates)")
        if state_updates:
            # MERGEを使用して状態をUPSERT

            # 挿入用データの準備
            rows_to_insert = [
                {
                    "race_code_uma_kol": u["race_code_uma_kol"],
                    "content_hash": u["content_hash"],
                    "exported_at": datetime.datetime.now().isoformat()
                }
                for u in state_updates.values()
            ]

            # 1. 一時テーブルへのロード (JSONロードは大量データに弱い場合があるが、hashとIDだけなら耐えられるか)
            job_config = bigquery.LoadJobConfig(
                write_disposition="WRITE_TRUNCATE",
                schema=[
                    bigquery.SchemaField("race_code_uma_kol", "STRING"),
                    bigquery.SchemaField("content_hash", "STRING"),
                    bigquery.SchemaField("exported_at", "TIMESTAMP"),
                ]
            )
            temp_table_id = f"{PROJECT_ID}.{DATASET_ID}.temp_race_uma_detail_bubble_state_updates"

            # チャンク分割してロードすることを検討すべきだが、コード簡略化のため一括
            # JSON Lines ファイルをGCSに書いてロードするのがベストプラクティスだが、ここでは直接ロード
            load_job = bq_client.load_table_from_json(rows_to_insert, temp_table_id, job_config=job_config)
            load_job.result() # 待機

            # 2. マージ実行
            merge_query = f"""
                MERGE `{PROJECT_ID}.{DATASET_ID}.{STATE_TABLE_NAME}` T
                USING `{temp_table_id}` S
                ON T.race_code_uma_kol = S.race_code_uma_kol
                WHEN MATCHED THEN
                  UPDATE SET content_hash = S.content_hash, exported_at = S.exported_at
                WHEN NOT MATCHED THEN
                  INSERT (race_code_uma_kol, content_hash, exported_at)
                  VALUES (race_code_uma_kol, content_hash, exported_at)
            """
            bq_client.query(merge_query).result()
            logger.info("状態管理テーブルが更新されました。")

            # 一時テーブルの削除
            bq_client.delete_table(temp_table_id, not_found_ok=True)

        return f"成功。 {processed_count} 行をエクスポートしました。", 200

    except Exception as e:
        logger.exception("実行中にエラーが発生しました。")
        return f"内部サーバーエラー: {e}", 500
