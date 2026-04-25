#!/bin/bash
set -euo pipefail  # توقف سریع در صورت بروز خطا، عالی برای debugging

# --- 1. تعریف کلید و توابع کمکی ---
AUTH_KEY="${AUTH_KEY:-"CHANGE_ME_TO_A_STRONG_SECRET"}"

# تابع خروجی JSON مشابه _json در Apps Script
json_response() {
  local json_content="$1"
  echo "::set-output name=result::$json_content"
  # برای سازگاری با state جدید، این متغیر محیطی را هم ست می‌کنیم.
  echo "RESULT=$json_content" >> $GITHUB_ENV
}

# --- 2. دریافت و اعتبارسنجی اولیه Payload ---
INPUT_PAYLOAD="$1"

# چک کردن خالی نبودن payload
if [ -z "$INPUT_PAYLOAD" ]; then
  json_response '{"error": "No payload provided"}'
  exit 1
fi

# --- 3. استخراج اطلاعات با jq ---
# این خطاها را می‌گیرد اگر payload جیسون معتبری نباشد
AUTH_K=$(echo "$INPUT_PAYLOAD" | jq -r '.k // empty')
MODE_BATCH=$(echo "$INPUT_PAYLOAD" | jq -r '.q | type')

if [ "$AUTH_K" != "$AUTH_KEY" ]; then
  json_response '{"error": "unauthorized"}'
  exit 1
fi

# --- 4. تعریف تابع اصلی Single Request ---
execute_single() {
  local req="$1"
  local url=$(echo "$req" | jq -r '.u // empty')
  local method=$(echo "$req" | jq -r '.m // "GET"')
  local headers=$(echo "$req" | jq -r '.h // {}')
  local body_b64=$(echo "$req" | jq -r '.b // empty')
  local content_type=$(echo "$req" | jq -r '.ct // empty')
  local follow_redirects=$(echo "$req" | jq -r '.r // true')

  if [ -z "$url" ]; then
    echo '{"e": "bad url"}'
    return
  fi

  # ساخت آرگومان‌های curl
  local curl_args=(-s -w "\n%{http_code}" --location) # --location دنبال کردن redirect
  if [ "$follow_redirects" != "true" ]; then
    curl_args=(-s -w "\n%{http_code}") # حذف --location
  fi

  curl_args+=(-X "$method")

  # پردازش هدرها
  if [ "$headers" != "{}" ] && [ -n "$headers" ]; then
    while IFS="=" read -r key value; do
      # هدرهای ممنوعه (مشابه SKIP_HEADERS)
      local lower_key=$(echo "$key" | tr '[:upper:]' '[:lower:]')
      case "$lower_key" in
        host|connection|content-length|transfer-encoding|proxy-connection|proxy-authorization|priority|te)
          continue ;;
      esac
      curl_args+=(-H "${key}: ${value}")
    done < <(echo "$headers" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  fi

  # پردازش بدنه درخواست
  if [ -n "$body_b64" ]; then
    local decoded_body=$(echo "$body_b64" | base64 -d)
    curl_args+=(--data-binary "$decoded_body")
    if [ -n "$content_type" ]; then
      curl_args+=(-H "Content-Type: ${content_type}")
    fi
  fi

  # اجرای curl
  local response=$(curl "${curl_args[@]}" "$url")
  local http_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')
  local response_headers="" # استخراج هدر در نسخه ساده شده امکان‌پذیر نیست
  local body_base64=$(echo -n "$response_body" | base64 -w 0)

  echo "{\"s\": $http_code, \"h\": {}, \"b\": \"$body_base64\"}"
}

# --- 5. اجرا بر اساس مد (Batch یا Single) ---

if [ "$MODE_BATCH" == "array" ]; then
  # حالت Batch (نسخه ساده شده و غیرموازی)
  echo "Batch mode detected. Processing sequentially (limit for safe log size)."
  batch_results="[]"
  # خواندن آرایه
  items_length=$(echo "$INPUT_PAYLOAD" | jq '.q | length')
  
  for (( i=0; i<$items_length; i++ ))
  do
    item=$(echo "$INPUT_PAYLOAD" | jq -c ".q[$i]")
    single_res=$(execute_single "$item")
    batch_results=$(echo "$batch_results" | jq --argjson res "$single_res" '. + [$res]')
  done
  
  json_response "{\"q\": $batch_results}"

else
  # حالت Single
  single_result=$(execute_single "$INPUT_PAYLOAD")
  json_response "$single_result"
fi
