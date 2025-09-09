#!/bin/bash

# === Step 0: Get BOT_TOKEN and USER_ID from arguments ===
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: bash $0 <BOT_TOKEN> <USER_ID>"
    exit 1
fi

BOT_TOKEN="$1"
USER_ID="$2"

# === Step 1: Ask VPS name ===
read -p "Enter VPS name (for bot logs): " VPS_NAME

# === Step 2: Update system & install dependencies ===
echo "Updating system and installing dependencies..."
sudo apt update -y
sudo apt install -y screen python3 python3-venv python3-pip

# === Step 3: Create project folder ===
BOT_DIR="$HOME/bot"
mkdir -p "$BOT_DIR"
cd "$BOT_DIR" || exit

# === Step 4: Create virtual environment ===
python3 -m venv venv
source venv/bin/activate

# === Step 5: Install required Python modules ===
pip install --upgrade pip
pip install requests

# === Step 6: Save bot script ===
BOT_FILE="$BOT_DIR/bot.py"
cat > "$BOT_FILE" <<'EOL'
import requests
import time
import os
import sys

# === Get arguments ===
if len(sys.argv) < 4:
    print("Usage: python bot.py <BOT_TOKEN> <USER_ID> <VPS_NAME>")
    sys.exit(1)

BOT_TOKEN = sys.argv[1]
USER_ID = sys.argv[2]
VPS_NAME = sys.argv[3]

LOG_FILE = os.path.expanduser("~/rl-swarm/node.log")
BASE_URL = f"https://api.telegram.org/bot{BOT_TOKEN}"

def get_updates(offset=None):
    try:
        resp = requests.get(f"{BASE_URL}/getUpdates", params={"timeout":30,"offset":offset})
        return resp.json()
    except Exception:
        return {"result":[]}

def send_message(chat_id, text):
    try:
        requests.post(f"{BASE_URL}/sendMessage", data={
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "MarkdownV2"
        })
    except Exception:
        pass

def escape_md(text: str) -> str:
    for ch in r"_*[]()~`>#+-=|{}.!":
        text = text.replace(ch, f"\\{ch}")
    return text

def tail_log(file_path, lines=10):
    if not os.path.exists(file_path):
        return "⚠️ Log file not found."
    with open(file_path, "r") as f:
        content = f.readlines()
        if not content:
            return "⚠️ Log file is empty."
        return escape_md("".join(content[-lines:]))

def main():
    print("🤖 Bot started. Waiting for /start...")
    update_id = None
    while True:
        updates = get_updates(update_id)
        if "result" in updates:
            for item in updates["result"]:
                update_id = item["update_id"] + 1
                message = item.get("message", {})
                chat_id = str(message.get("chat", {}).get("id",""))
                if not chat_id or chat_id != USER_ID:
                    continue
                text = message.get("text","")
                if text == "/start":
                    logs = tail_log(LOG_FILE,10)
                    msg = f"📌 *VPS:* `{escape_md(VPS_NAME)}`\n\n📝 *Last 10 log lines:*\n\n```text\n{logs}\n```"
                    send_message(chat_id,msg)
        time.sleep(1)

if __name__ == "__main__":
    main()
EOL

# === Step 7: Run bot in detached screen ===
echo "Starting bot in detached screen session named 'gensyn-bot'..."
screen -S gensyn-bot -dm bash -c "source $BOT_DIR/venv/bin/activate && python $BOT_FILE '$BOT_TOKEN' '$USER_ID' '$VPS_NAME'"

echo "✅ Bot is running in detached screen session 'gensyn-bot'."
echo "Use 'screen -r gensyn-bot' to attach and see logs if needed."
