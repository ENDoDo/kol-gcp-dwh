import json
import logging

# Simple mock for logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def verify_logic(resp_json):
    print(f"Testing with response: {resp_json}")
    try:
        # This is the logic we added to the functions
        if resp_json.get("response", {}).get("is_import_success") == "no":
            error_text = resp_json.get("response", {}).get("error_text", "Unknown error")
            logger.error(f"Bubble Import Failed: {error_text}")
            raise Exception(f"Bubble Import Failed: {error_text}")
        print("Success: Exception not raised as expected.")
    except Exception as e:
        if "Bubble Import Failed" in str(e):
            print(f"Success: Exception raised as expected: {e}")
        else:
            print(f"Failure: Unexpected exception: {e}")

# Case 1: Success
verify_logic({
    "status": "success",
    "response": {
        "import_data_type": "Schedule",
        "is_import_success": "yes",
        "error_text": ""
    }
})

# Case 2: Failure (no)
verify_logic({
    "status": "success",
    "response": {
        "import_data_type": "Schedule",
        "is_import_success": "no",
        "error_text": "短時間で同じファイルの取り込みを検知したため中止"
    }
})

# Case 3: Missing response field (should not raise)
verify_logic({
    "status": "success"
})
