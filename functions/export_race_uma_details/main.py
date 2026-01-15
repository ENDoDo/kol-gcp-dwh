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
STATE_TABLE_NAME = "race_uma_details_export_state"
FTP_HOST = "smartkb.mixh.jp"
BUBBLE_API_URL = os.environ.get("BUBBLE_API_URL")
BUBBLE_API_KEY_SECRET_ID = os.environ.get("BUBBLE_API_KEY_SECRET_ID")
CSV_BASE_URL = os.environ.get("CSV_BASE_URL", "https://kol-bi.jp/umasiri.dev")

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
def export_race_uma_details(request):
    """更新されたレース詳細情報(race_uma_details)をFTPにエクスポートするHTTP Cloud Function"""
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
                        (SELECT AS STRUCT * EXCEPT(created, modified) FROM UNNEST([t]))
                    ))) as current_hash
                FROM `{PROJECT_ID}.{DATASET_ID}.race_uma_details` t
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

        # CSV出力用フィールド定義
        fieldnames = [
            "race_code_uma_kol", "race_code_uma_jvd", "race_code_kol", "race_code_jvd", "keibajo_code_jvd", "keibajo_code_kol",
            "hasso_date", "kaiji", "nichiji", "race_bango", "race_bango_num", "waku_kubun", "wakuban", "umaban", "umaban_num", "umaban_even",
            "bamei", "seibetsu_code", "seibetsu_code_label", "barei", "barei_num", "futan_juryo", "futan_juryo_float",
            "blinker_shiyo_kubun", "blinker_shiyo_kubun_label", "rating", "rating_float",
            "banushimei", "banushimei_ryakusho", "ketto_toroku_bango_kol", "ketto1_f_hanshoku_toroku_bango", "ketto1_f_bamei",
            "ketto2_m_hanshoku_toroku_bango", "ketto2_m_bamei", "ketto5_mf_hanshoku_toroku_bango", "ketto5_mf_bamei", "kyuyo_riyu",
            "kishumei", "kishumei_ryakusho", "kishu_code", "kishu_tozai_shozoku_code", "kishu_tozai_shozoku_code_label",
            "kishu_minarai_code", "kishu_minarai_code_label", "kishu_norikawari_kubun", "kishu_norikawari_kubun_label",
            "kishu_shozokubasho_code", "kishu_shozokubasho_code_label", "kishu_shozoku_chokyoshi_code",
            "chokyoshi_code", "chokyoshimei", "chokyoshimei_ryakusho", "chokyoshi_shozokubasho_code", "chokyoshi_shozokubasho_code_label",
            "chokyoshi_tracen_kubun", "chokyoshi_tracen_kubun_label",
            "chokyo_den_oikiri_flag", "chokyo_den_oikiri_flag_label", "chokyo_den_oikiri_kijosha",
            "chokyo_den_oikiri_nengappi_date", "chokyo_den_oikiri_nengappi",
            "chokyo_den_oikiri_basho", "chokyo_den_oikiri_course", "chokyo_den_oikiri_course_kubun", "chokyo_den_oikiri_basho_course_label",
            "chokyo_den_oikiri_babajotai", "chokyo_den_oikiri_hanro_pool_kaisu_int",
            "chokyo_den_oikiri_8f", "chokyo_den_oikiri_8f_float", "chokyo_den_oikiri_7f", "chokyo_den_oikiri_7f_float",
            "chokyo_den_oikiri_6f", "chokyo_den_oikiri_6f_float", "chokyo_den_oikiri_5f", "chokyo_den_oikiri_5f_float",
            "chokyo_den_oikiri_4f", "chokyo_den_oikiri_4f_float", "chokyo_den_oikiri_3f", "chokyo_den_oikiri_3f_float",
            "chokyo_den_oikiri_2f_float", "chokyo_den_oikiri_1f", "chokyo_den_oikiri_1f_float",
            "chokyo_den_oikiri_lap_8f", "chokyo_den_oikiri_lap_7f", "chokyo_den_oikiri_lap_6f", "chokyo_den_oikiri_lap_5f",
            "chokyo_den_oikiri_lap_4f", "chokyo_den_oikiri_lap_3f", "chokyo_den_oikiri_lap_2f", "chokyo_den_oikiri_lap_group",
            "chokyo_den_oikiri_5f_wood_kubun", "chokyo_den_oikiri_4f_wood_kubun", "chokyo_den_oikiri_1f_wood_kubun", "chokyo_den_oikiri_4f_hanro_kubun",
            "shirushi_hanro_4f_flag", "shirushi_hanro_1f_flag", "shirushi_wood_6f_flag", "shirushi_wood_1f_flag",
            "shirushi_awase_senchaku_flag", "shirushi_point", "shirushi_kubun_yosou_tansho_ninkijun", "shirushi_kubun_rank",
            "shirushi_shirushi_label", "shirushi_shirushi_num",
            "chokyo_den_oikiri_ichidori", "chokyo_den_oikiri_ichidori_label", "chokyo_den_oikiri_ashiiro", "chokyo_den_oikiri_ashiiro_label",
            "chokyo_den_oikiri_yajirushi", "chokyo_den_oikiri_yajirushi_label", "chokyo_den_oikiri_reigai",
            "chokyo_den_chokyo1_flag", "chokyo_den_chokyo1_flag_label", "chokyo_den_chokyo1_kijosha",
            "chokyo_den_chokyo1_nengappi", "chokyo_den_chokyo1_nengappi_date",
            "chokyo_den_chokyo1_basho", "chokyo_den_chokyo1_course", "chokyo_den_chokyo1_course_kubun", "chokyo_den_chokyo1_basho_course_label",
            "chokyo_den_chokyo1_babajotai", "chokyo_den_chokyo1_hanro_pool_kaisu_int",
            "chokyo_den_chokyo1_8f", "chokyo_den_chokyo1_8f_float", "chokyo_den_chokyo1_7f", "chokyo_den_chokyo1_7f_float",
            "chokyo_den_chokyo1_6f", "chokyo_den_chokyo1_6f_float", "chokyo_den_chokyo1_5f", "chokyo_den_chokyo1_5f_float",
            "chokyo_den_chokyo1_4f", "chokyo_den_chokyo1_4f_float", "chokyo_den_chokyo1_3f", "chokyo_den_chokyo1_3f_float",
            "chokyo_den_chokyo1_2f_float", "chokyo_den_chokyo1_1f", "chokyo_den_chokyo1_1f_float",
            "chokyo_den_chokyo1_ichidori", "chokyo_den_chokyo1_ichidori_label", "chokyo_den_chokyo1_ashiiro", "chokyo_den_chokyo1_ashiiro_label",
            "chokyo_den_chokyo1_yajirushi", "chokyo_den_chokyo1_yajirushi_label", "chokyo_den_chokyo1_reigai",
            "chokyo_den_chokyo2_flag", "chokyo_den_chokyo2_flag_label", "chokyo_den_chokyo2_kijosha",
            "chokyo_den_chokyo2_nengappi", "chokyo_den_chokyo2_nengappi_date",
            "chokyo_den_chokyo2_basho", "chokyo_den_chokyo2_course", "chokyo_den_chokyo2_course_kubun", "chokyo_den_chokyo2_basho_course_label",
            "chokyo_den_chokyo2_babajotai", "chokyo_den_chokyo2_hanro_pool_kaisu_int",
            "chokyo_den_chokyo2_8f", "chokyo_den_chokyo2_8f_float", "chokyo_den_chokyo2_7f", "chokyo_den_chokyo2_7f_float",
            "chokyo_den_chokyo2_6f", "chokyo_den_chokyo2_6f_float", "chokyo_den_chokyo2_5f", "chokyo_den_chokyo2_5f_float",
            "chokyo_den_chokyo2_4f", "chokyo_den_chokyo2_4f_float", "chokyo_den_chokyo2_3f", "chokyo_den_chokyo2_3f_float",
            "chokyo_den_chokyo2_2f_float", "chokyo_den_chokyo2_1f", "chokyo_den_chokyo2_1f_float",
            "chokyo_den_chokyo2_ichidori", "chokyo_den_chokyo2_ichidori_label", "chokyo_den_chokyo2_ashiiro", "chokyo_den_chokyo2_ashiiro_label",
            "chokyo_den_chokyo2_yajirushi", "chokyo_den_chokyo2_yajirushi_label", "chokyo_den_chokyo2_reigai",
            "chokyo_den_chokyo3_flag", "chokyo_den_chokyo3_flag_label", "chokyo_den_chokyo3_kijosha",
            "chokyo_den_chokyo3_nengappi", "chokyo_den_chokyo3_nengappi_date",
            "chokyo_den_chokyo3_basho", "chokyo_den_chokyo3_course", "chokyo_den_chokyo3_course_kubun", "chokyo_den_chokyo3_basho_course_label",
            "chokyo_den_chokyo3_babajotai", "chokyo_den_chokyo3_hanro_pool_kaisu_int",
            "chokyo_den_chokyo3_8f", "chokyo_den_chokyo3_8f_float", "chokyo_den_chokyo3_7f", "chokyo_den_chokyo3_7f_float",
            "chokyo_den_chokyo3_6f", "chokyo_den_chokyo3_6f_float", "chokyo_den_chokyo3_5f", "chokyo_den_chokyo3_5f_float",
            "chokyo_den_chokyo3_4f", "chokyo_den_chokyo3_4f_float", "chokyo_den_chokyo3_3f", "chokyo_den_chokyo3_3f_float",
            "chokyo_den_chokyo3_2f_float", "chokyo_den_chokyo3_1f", "chokyo_den_chokyo3_1f_float",
            "chokyo_den_chokyo3_ichidori", "chokyo_den_chokyo3_ichidori_label", "chokyo_den_chokyo3_ashiiro", "chokyo_den_chokyo3_ashiiro_label",
            "chokyo_den_chokyo3_yajirushi", "chokyo_den_chokyo3_yajirushi_label", "chokyo_den_chokyo3_reigai",
            "chokyo_sei_flag", "chokyo_sei_flag_label", "chokyo_sei_kijosha", "chokyo_sei_kijosha_kubun",
            "chokyo_sei_kijosha_equal_kishumei_flag", "chokyo_sei_nengappi", "chokyo_sei_nengappi_label", "chokyo_sei_nengappi_date",
            "chokyo_sei_basho", "chokyo_sei_course", "chokyo_sei_course_kubun", "chokyo_sei_basho_course_label",
            "chokyo_sei_babajotai", "chokyo_sei_hanro_pool_kaisu_int",
            "chokyo_sei_8f", "chokyo_sei_8f_float", "chokyo_sei_7f", "chokyo_sei_7f_float", "chokyo_sei_6f", "chokyo_sei_6f_float",
            "chokyo_sei_5f", "chokyo_sei_5f_float", "chokyo_sei_4f", "chokyo_sei_4f_float", "chokyo_sei_3f", "chokyo_sei_3f_float",
            "chokyo_sei_2f_float", "chokyo_sei_1f", "chokyo_sei_1f_float",
            "chokyo_sei_lap_8f", "chokyo_sei_lap_7f", "chokyo_sei_lap_6f", "chokyo_sei_lap_5f",
            "chokyo_sei_lap_4f", "chokyo_sei_lap_3f", "chokyo_sei_lap_2f", "chokyo_sei_lap_group",
            "chokyo_sei_5f_wood_kubun", "chokyo_sei_4f_wood_kubun", "chokyo_sei_1f_wood_kubun", "chokyo_sei_4f_hanro_kubun",
            "chokyo_sei_ichidori", "chokyo_sei_ichidori_label", "chokyo_sei_ashiiro", "chokyo_sei_ashiiro_label",
            "chokyo_sei_yajirushi", "chokyo_sei_yajirushi_label", "chokyo_sei_reigai",
            "chokyo_sei_check_time_1f_flag", "chokyo_sei_check_time_4f_6f_flag",
            "speed_sisu_last_1", "speed_sisu_last_1_float", "speed_sisu_last_2", "speed_sisu_last_2_float", "speed_sisu_last_3", "speed_sisu_last_3_float",
            "speed_sisu_last_4", "speed_sisu_last_4_float", "speed_sisu_last_5", "speed_sisu_last_5_float",
            "rotation1", "rotation1_label", "rotation2", "rotation2_label", "rotation3", "rotation3_label", "rotation4", "rotation4_label",
            "rotation5", "rotation5_label", "rotation6", "rotation6_label", "rotation7", "rotation7_label", "rotation8", "rotation8_label", "zensou_kankaku",
            "bataiju", "bataiju_kubun", "bataiju_zensou", "bataiju_kubun_zensou", "kyori_kubun_zensou", "kyori_extension_flag", "kyori_shortening_flag",
            "ensei_kansai_to_kantou_flag", "ensei_kantou_to_kansai_flag", "ensei_flag", "track_code1_label_dirtsiba_zensou", "siba_to_dirt_flag", "dirt_to_siba_flag",
            "record_shisu", "record_shisu_num", "zogen_sa", "zogen_sa_num", "tansho_ninkijun", "tansho_ninkijun_num", "tansho_odds", "tansho_odds_float",
            "kakutei_chakujun", "kakutei_chakujun_num", "tansho_haraimodoshi", "tansho_haraimodoshi_num", "fukusho_haraimodoshi", "fukusho_haraimodoshi_num",
            "ijo_kubun_code1", "ijo_kubun_code1_label", "ijo_kubun_code2", "ijo_kubun_code2_label", "nyusen_juni", "nyusen_juni_num", "record_flag", "record_flag_label",
            "soha_time", "soha_time_float", "soha_time_label", "chakusa_code1", "chakusa_code1_num", "chakusa_code2", "chakusa_code2_label", "chakusa_label",
            "time_sa", "time_sa_float", "zenhan_3f", "zenhan_3f_float", "kohan_3f", "kohan_3f_float",
            "corner1_juni", "corner1_juni_label", "corner2_juni", "corner2_juni_label", "corner3_juni", "corner3_juni_label", "corner4_juni", "corner4_juni_label", "corner4_ichidori", "corner4_ichidori_label",
            "race_name", "kyori_kubun", "keibajo_name", "chuo_chiho_kubun", "chuo_chiho_kubun_label", "kyosomei_15moji", "kyosomei_7moji",
            "grade_code", "grade_code_label", "jpn_flag", "jpn_flag_label", "bettei_barei_handicap_summary_code", "bettei_barei_handicap_summary_code_label", "bettei_barei_handicap_detail",
            "kyoso_joken_age_limit", "kyoso_joken_age_limit_label", "kyoso_joken_kubun", "kyoso_joken_kubun_label", "heichi_shogai_kubun", "heichi_shogai_kubun_label",
            "track_code1_dirtsiba", "track_code1_dirtsiba_label", "track_code2_LRS", "track_code2_LRS_label", "track_code3_inout", "track_code3_inout_label",
            "course_kubun", "course_kubun_label", "kyori", "toroku_tosu_num", "torikeshi_tosu_num", "tenko_code", "tenko_code_label",
            "babajotai_code", "babajotai_code_label", "pace_yosou", "pace_yosou_label", "pace_kekka", "pace_kekka_label", "race_tanpyo",
            "juryo_handicap_flag", "keibajo_komawari_curve4_flag", "keibajo_omawari_curve4_flag", "keibajo_straight_short_flag", "keibajo_straight_long_flag",
            "created", "modified"
        ]

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
            table_name = "race_uma_details"
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

                # Bubble APIへの通知 (一時停止中)
                # if BUBBLE_API_URL and BUBBLE_API_KEY_SECRET_ID:
                #     ftp_directory = os.environ.get("FTP_DIRECTORY")
                #     # FTPディレクトリの考慮
                #     if ftp_directory:
                #         dir_path = ftp_directory.strip("/")
                #         csv_url = f"{CSV_BASE_URL}/{dir_path}/{filename}"
                #     else:
                #         csv_url = f"{CSV_BASE_URL}/{filename}"

                #     logger.info(f"通知対象CSV URL: {csv_url}")
                #     api_key = get_secret(BUBBLE_API_KEY_SECRET_ID)
                #     headers = {
                #         "Content-Type": "application/json",
                #         "Authorization": f"Bearer {api_key}"
                #     }
                #     payload = {
                #         "csv_url": csv_url
                #     }
                #     try:
                #         logger.info(f"Bubble APIへリクエストを送信します: URL={BUBBLE_API_URL}")
                #         response = requests.post(BUBBLE_API_URL, json=payload, headers=headers)
                #         response.raise_for_status()
                #         logger.info(f"Bubble APIへの通知に成功しました ({filename}): {response.json()}")
                #     except Exception as e:
                #         logger.error(f"Bubble APIへの通知に失敗しました ({filename}): {e}")
                #         # 続行する
                # else:
                #     if i == 0: # ログ過多防止のため初回のみログ出力
                #          logger.info("Bubble API設定がされていないため、通知をスキップします。")
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
            temp_table_id = f"{PROJECT_ID}.{DATASET_ID}.temp_race_uma_details_state_updates"

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
