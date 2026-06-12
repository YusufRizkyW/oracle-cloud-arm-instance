#!/bin/bash

# Fungsi untuk mengirim pesan teks biasa/markdown
send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" > /dev/null
}

# Fungsi untuk mengirim file (Auto-backup Private Key)
send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    if [ -f "$file_path" ]; then
        echo "${GPG_PASSWORD}" | gpg --batch --yes --passphrase-fd 0 -c "$file_path"

        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "document=@${file_path}.gpg" \
            -F "caption=${caption}" > /dev/null
        
        rm -f "${file_path}.gpg"
        
        send_telegram_message "✅ *Successfully backup private key!*\n\n*File:* \`${file_path}\`"
    else
        send_telegram_message "⚠️ *Error:* File \`${file_path}\` not found to backup!"
    fi
}   

