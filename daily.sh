#!/bin/bash

# Check if terminal supports colors
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors)" -ge 8 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    BOLD='\033[1m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
    BOLD=''
fi

CTRL_C_COUNT=0
#AAAAAAAAAAAAAAAAA
# Trap Ctrl+C
trap 'handle_ctrl_c' SIGINT

# Handle Ctrl+C
handle_ctrl_c() {
    ((CTRL_C_COUNT++))
    if [ $CTRL_C_COUNT -ge 2 ]; then
        echo -e "${RED}🚨 Multiple Ctrl+C detected. Exiting...${NC}"
        cleanup
        exit 0
    fi
    echo -e "${RED}🚨 Ctrl+C detected. Exiting...${NC}"
    cleanup
    exit 0
}

# Cleanup temporary files (excluding upload_logs)
cleanup() {
    echo -e "${BLUE}🧹 Cleaning up temporary files (preserving upload_logs)...${NC}"
    rm -f tmp.json list.txt video_*.mp4 pix_*.mp4 pex_*.mp4 2>/dev/null
    echo -e "${GREEN}✅ Upload logs preserved in ./upload_logs/${NC}"
}

# Setup Python virtual environment
setup_venv() {
    VENV_DIR="$HOME/pipe_venv"
    echo -e "${BLUE}🛠️ Setting up Python virtual environment at $VENV_DIR...${NC}"
  
    # Ensure python3 and pip are available
    if ! command -v python3 >/dev/null 2>&1 || ! command -v pip3 >/dev/null 2>&1; then
        echo -e "${BLUE}📦 Installing Python3 and pip...${NC}"
        sudo apt update && sudo apt install -y python3 python3-pip python3-venv
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to install Python3 or pip!${NC}"
            exit 1
        fi
    fi

    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to create virtual environment!${NC}"
            exit 1
        fi
    fi

    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip
    for package in yt-dlp requests moviepy; do
        if ! pip show "$package" >/dev/null 2>&1; then
            echo -e "${YELLOW}📦 Installing $package...${NC}"
            RETRY_COUNT=0
            MAX_RETRIES=3
            while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                pip install "$package"
                if [ $? -eq 0 ]; then
                    break
                fi
                ((RETRY_COUNT++))
                echo -e "${YELLOW}⚠️ Retry $RETRY_COUNT/$MAX_RETRIES for $package...${NC}"
                sleep 2
            done
            if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
                echo -e "${RED}❌ Failed to install $package after $MAX_RETRIES attempts!${NC}"
                deactivate
                exit 1
            fi
        fi
    done
    echo -e "${GREEN}✅ All required packages installed successfully in venv!${NC}"
    deactivate
}

# Install pipe node if not found
install_pipe() {
    echo -e "${BLUE}🔍 Checking if Pipe is installed...${NC}"
    if command -v pipe >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Pipe is already installed!${NC}"
        return 0
    fi

    echo -e "${BLUE}🔄 Installing dependencies for Pipe...${NC}"
    sudo apt update && sudo apt install -y curl build-essential git wget lz4 jq make gcc libgbm1 pkg-config libssl-dev tar clang bsdmainutils unzip libleveldb-dev libclang-dev ninja-build
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to install dependencies!${NC}"
        exit 1
    fi

    echo -e "${BLUE}🦀 Installing Rust...${NC}"
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to install Rust!${NC}"
        exit 1
    fi
    source "$HOME/.cargo/env"

    echo -e "${BLUE}📥 Cloning and installing Pipe...${NC}"
    git clone https://github.com/PipeNetwork/pipe.git "$HOME/pipe"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to clone Pipe repository!${NC}"
        exit 1
    fi

    cd "$HOME/pipe"
    cargo install --path .
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to install Pipe!${NC}"
        exit 1
    fi
    cd "$HOME"

    setup_pipe_path
    if ! command -v pipe >/dev/null 2>&1; then
        echo -e "${RED}❌ Pipe installation failed! Checking PATH: $PATH${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Pipe installed successfully!${NC}"
}

# Setup pipe path
setup_pipe_path() {
    if [ -f "$HOME/.cargo/bin/pipe" ]; then
        if ! grep -q "export PATH=\$HOME/.cargo/bin:\$PATH" ~/.bashrc; then
            echo 'export PATH=$HOME/.cargo/bin:$PATH' >> ~/.bashrc
            echo -e "${GREEN}✅ Added pipe path to ~/.bashrc.${NC}"
        fi
        export PATH=$HOME/.cargo/bin:$PATH
        echo -e "${GREEN}✅ Updated PATH with pipe location.${NC}"
        if [ -f "$HOME/.cargo/env" ]; then
            source "$HOME/.cargo/env"
            echo -e "${GREEN}✅ Reloaded cargo environment.${NC}"
        fi
        chmod +x "$HOME/.cargo/bin/pipe"
        echo -e "${GREEN}✅ Ensured pipe is executable.${NC}"
    else
        echo -e "${YELLOW}⚠️ Pipe binary not found. Triggering installation...${NC}"
        install_pipe
    fi
}

# Check and handle dependencies like ffmpeg and jq
check_dependencies() {
    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ ffmpeg not found. Attempting to install...${NC}"
        sudo apt update && sudo apt install -y ffmpeg
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to install ffmpeg. Please install manually.${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ ffmpeg installed successfully.${NC}"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ jq not found. Attempting to install...${NC}"
        sudo apt update && sudo apt install -y jq
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to install jq. Please install manually.${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ jq installed successfully.${NC}"
    fi
}

# Upload videos
upload_videos() {
    VENV_DIR="$HOME/pipe_venv"
    if [ ! -d "$VENV_DIR" ]; then
        setup_venv
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to set up virtual environment. Exiting.${NC}"
            cleanup
            exit 1
        fi
    fi

    source "$VENV_DIR/bin/activate"

    # Set API keys
    if [ ! -f "$HOME/.pexels_api_key" ]; then
        echo "pexels: iur1f5KGwvSIR1xr8I1t3KR3NP88wFXeCyV12ibHnioNXQYTy95KhE69" > "$HOME/.pexels_api_key"
    fi
    if [ ! -f "$HOME/.pixabay_api_key" ]; then
        echo "51848865-07253475f9fc0309b02c38a39" > "$HOME/.pixabay_api_key"
    fi

    num_uploads=$((RANDOM % 3 + 5))  # Random between 5 and 7
    echo -e "${GREEN}📦 Number of uploads for today: $num_uploads${NC}"

    mkdir -p upload_logs

    queries=(
        "random full hd"
        "nature 4k"
        "travel vlog"
        "wildlife documentary"
        "relaxing music video"
        "space exploration"
        "cooking tutorial"
        "city timelapse"
        "funny animals"
        "motivation speech"
        "gaming highlights"
        "fitness workout"
        "mountain climbing"
        "ocean waves"
        "cars drifting"
        "dance performance"
        "history documentary"
        "cinematic short film"
        "productivity tips"
        "study music"
        "coding tutorial"
        "ai technology"
        "sports highlights"
        "street food india"
        "drone footage"
        "concert live"
        "luxury lifestyle"
        "meditation video"
        "camping adventure"
        "art tutorial"
        "painting timelapse"
        "forest sounds"
        "rivers and lakes"
        "sunrise timelapse"
        "motivational video"
        "chess strategy"
        "crypto news"
        "fashion show"
        "cats compilation"
        "dogs funny"
        "beach sunset"
        "underwater world"
        "city nightlife"
        "science experiment"
        "robotics demo"
        "festival celebration"
        "desert safari"
        "volcano eruption"
        "aurora borealis"
        "rainforest animals"
        "slow motion video"
        "car review"
        "bike stunts"
        "boxing highlights"
        "football worldcup"
        "basketball dunks"
        "tennis rally"
        "swimming competition"
        "skateboard tricks"
        "parkour stunts"
        "martial arts"
        "bollywood dance"
        "hollywood trailer"
        "anime opening"
        "cartoon funny"
        "lego build"
        "minecraft gameplay"
        "fortnite highlights"
        "valorant montage"
        "pubg mobile"
        "gta 5 gameplay"
        "cyberpunk edit"
        "vr experience"
        "ai generated art"
        "drone mountains"
        "drone desert"
        "drone cityscape"
        "rain sounds"
        "campfire night"
        "lofi beats"
        "guitar cover"
        "piano performance"
        "orchestra live"
        "standup comedy"
        "magic tricks"
        "science facts"
        "astronomy stars"
        "galaxy timelapse"
        "rocket launch"
        "mars exploration"
        "saturn rings"
        "black hole animation"
        "earth from space"
        "climate change"
        "tsunami waves"
        "earthquake footage"
        "tornado storm"
        "hurricane damage"
        "snowfall winter"
        "spring flowers"
        "autumn leaves"
    )

    for ((i=1; i<=num_uploads; i++)); do
        # Random sleep between uploads (1-3 hours in seconds: 3600 to 10800)
        if [ $i -gt 1 ]; then
            sleep_time=$((RANDOM % 7201 + 3600))
            echo -e "${BLUE}⏳ Sleeping for $(($sleep_time / 3600)) hours $(($sleep_time % 3600 / 60)) minutes before next upload...${NC}"
            sleep $sleep_time
        fi

        log_file="upload_logs/upload_$(date +%Y%m%d_%H%M%S).log"
        echo -e "${BLUE}📹 Starting upload $i/$num_Uploads...${NC}" | tee -a "$log_file"

        query=${queries[$RANDOM % ${#queries[@]}]}
        echo -e "${YELLOW}🔍 Using query: \"$query\"${NC}" | tee -a "$log_file"

        sources=("youtube" "pixabay" "pexels")
        success=false
        for source in "${sources[@]}"; do
            echo -e "${YELLOW}🔍 Trying $source...${NC}" | tee -a "$log_file"

            random_suffix=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
            output_file="video_$random_suffix.mp4"

            download_success=false
            if [ "$source" = "youtube" ]; then
                python3 video_downloader.py "$query" "$output_file" 2>&1 | tee -a "$log_file"
            elif [ "$source" = "pixabay" ]; then
                python3 pixabay_downloader.py "$query" "$output_file" 2>&1 | tee -a "$log_file"
            elif [ "$source" = "pexels" ]; then
                python3 pexels_downloader.py "$query" "$output_file" 2>&1 | tee -a "$log_file"
            fi

            if [ -f "$output_file" ] && [ $(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null) -gt 50000000 ]; then
                download_success=true
            fi

            if $download_success; then
                echo -e "${BLUE}⬆️ Uploading video from $source...${NC}" | tee -a "$log_file"

                # Handle pipe command not found
                if ! command -v pipe >/dev/null 2>&1; then
                    echo -e "${YELLOW}⚠️ Pipe command not found. Installing...${NC}" | tee -a "$log_file"
                    install_pipe
                    if ! command -v pipe >/dev/null 2>&1; then
                        echo -e "${RED}❌ Pipe installation failed. Exiting.${NC}" | tee -a "$log_file"
                        deactivate
                        cleanup
                        exit 1
                    fi
                fi

                # Upload with retry
                RETRY_COUNT=0
                MAX_RETRIES=3
                while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                    upload_output=$(pipe upload-file "$output_file" "$output_file" 2>&1)
                    if [ $? -eq 0 ]; then
                        echo "$upload_output" | tee -a "$log_file"
                        file_id=$(echo "$upload_output" | grep "File ID (Blake3)" | awk '{print $NF}')
                        link_output=$(pipe create-public-link "$output_file" 2>&1)
                        echo "$link_output" | tee -a "$log_file"
                        direct_link=$(echo "$link_output" | grep "Direct link" -A 1 | tail -n 1 | awk '{$1=$1};1')
                        social_link=$(echo "$link_output" | grep "Social media link" -A 1 | tail -n 1 | awk '{$1=$1};1')

                        if [ -n "$file_id" ]; then
                            if [ ! -f "file_details.json" ]; then
                                echo "[]" > file_details.json
                            fi
                            jq --arg fn "$output_file" --arg fid "$file_id" --arg dl "$direct_link" --arg sl "$social_link" \
                                '. + [{"file_name": $fn, "file_id": $fid, "direct_link": $dl, "social_link": $sl}]' \
                                file_details.json > tmp.json && mv tmp.json file_details.json
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}✅ Upload $i successful from $source.${NC}" | tee -a "$log_file"
                                echo -e "${YELLOW}🔗 Public link: $social_link${NC}" | tee -a "$log_file"
                                success=true
                            else
                                echo -e "${RED}❌ Failed to save file details for upload $i.${NC}" | tee -a "$log_file"
                            fi
                        else
                            echo -e "${RED}❌ Failed to extract File ID for upload $i.${NC}" | tee -a "$log_file"
                        fi
                        break
                    else
                        echo -e "${RED}❌ Upload failed: $upload_output${NC}" | tee -a "$log_file"
                        ((RETRY_COUNT++))
                        echo -e "${YELLOW}⚠️ Retry $RETRY_COUNT/$MAX_RETRIES for upload...${NC}" | tee -a "$log_file"
                        sleep 10
                    fi
                done

                if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
                    echo -e "${RED}❌ Upload failed after $MAX_RETRIES attempts.${NC}" | tee -a "$log_file"
                fi

                rm -f "$output_file"
            else
                echo -e "${RED}❌ Download failed or file too small from $source.${NC}" | tee -a "$log_file"
                rm -f "$output_file"
            fi

            if $success; then
                break
            fi
        done

        if ! $success; then
            echo -e "${RED}❌ Upload $i failed from all sources.${NC}" | tee -a "$log_file"
        fi
    done

    deactivate
    echo -e "${GREEN}✅ Upload logs saved in ./upload_logs/${NC}"
}

# Video downloader scripts
cat << 'EOF' > video_downloader.py
import yt_dlp
import os
import sys
import time
import random
import string
import subprocess
import shutil
try:
    from moviepy.editor import VideoFileClip, concatenate_videoclips
    MOVIEPY_AVAILABLE = True
except ImportError:
    MOVIEPY_AVAILABLE = False
def format_size(bytes_size):
    return f"{bytes_size/(1024*1024):.2f} MB"
def format_time(seconds):
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{mins:02d}:{secs:02d}"
def draw_progress_bar(progress, total, width=50):
    percent = progress / total * 100
    filled = int(width * progress // total)
    bar = '█' * filled + '-' * (width - filled)
    return f"[{bar}] {percent:.1f}%"
def check_ffmpeg():
    return shutil.which("ffmpeg") is not None
def concatenate_with_moviepy(files, output_file):
    if not MOVIEPY_AVAILABLE:
        print("❌ moviepy is not installed. Cannot concatenate with moviepy.")
        return False
    try:
        clips = []
        for fn in files:
            if os.path.exists(fn) and os.path.getsize(fn) > 0:
                try:
                    clip = VideoFileClip(fn)
                    clips.append(clip)
                except Exception as e:
                    print(f"⚠️ Skipping invalid file {fn}: {str(e)}")
        if not clips:
            print("❌ No valid video clips to concatenate.")
            return False
        final_clip = concatenate_videoclips(clips, method="compose")
        final_clip.write_videofile(output_file, codec="libx264", audio_codec="aac", temp_audiofile="temp-audio.m4a", remove_temp=True, threads=2)
        for clip in clips:
            clip.close()
        final_clip.close()
        return os.path.exists(output_file) and os.path.getsize(output_file) > 0
    except Exception as e:
        print(f"❌ Moviepy concatenation failed: {str(e)}")
        return False
def download_videos(query, output_file, target_size_mb=1000, max_filesize=1100*1024*1024, min_filesize=50*1024*1024):
    ydl_opts = {
        'format': 'best',
        'noplaylist': True,
        'quiet': True,
        'progress_hooks': [progress_hook],
        'outtmpl': '%(title)s.%(ext)s'
    }
    total_downloaded = 0
    total_size = 0
    start_time = time.time()
    downloaded_files = []
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(f"ytsearch20:{query}", download=False)
            videos = info.get("entries", [])
            candidates = []
            for v in videos:
                size = v.get("filesize") or v.get("filesize_approx")
                if size and min_filesize <= size <= max_filesize:
                    candidates.append((size, v))
            if not candidates:
                print("❌ No suitable videos found (at least 50MB and up to ~1GB).")
                return
            for size, v in sorted(candidates, key=lambda x: -x[0]):
                if total_size + size <= target_size_mb * 1024 * 1024:
                    total_size += size
                    current_file = len(downloaded_files) + 1
                    print(f"🎬 Downloading video {current_file}: {v['title']} ({format_size(size)})")
                    ydl.download([v['webpage_url']])
                    filename = ydl.prepare_filename(v)
                    if os.path.exists(filename) and os.path.getsize(filename) > 0:
                        downloaded_files.append(filename)
                        total_downloaded += size
                    else:
                        print(f"❌ Failed to download or empty file: {filename}")
                        continue
                    elapsed = time.time() - start_time
                    speed = total_downloaded / (1024*1024*elapsed) if elapsed > 0 else 0
                    eta = (total_size - total_downloaded) / (speed * 1024*1024) if speed > 0 else 0
                    print(f"✅ Overall Progress: {draw_progress_bar(total_downloaded, total_size)} "
                          f"({format_size(total_downloaded)}/{format_size(total_size)}) "
                          f"(Speed: {speed:.2f} MB/s ETA: {format_time(eta)})")
        if not downloaded_files:
            print("❌ No videos found close to 1GB.")
            return
        if len(downloaded_files) == 1:
            os.rename(downloaded_files[0], output_file)
        else:
            success = False
            if check_ffmpeg():
                print("🔗 Concatenating videos with ffmpeg...")
                with open('list.txt', 'w') as f:
                    for fn in downloaded_files:
                        f.write(f"file '{fn}'\n")
                result = subprocess.run(['ffmpeg', '-f', 'concat', '-safe', '0', '-i', 'list.txt', '-c', 'copy', output_file], capture_output=True, text=True)
                if result.returncode == 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                    success = True
                else:
                    print(f"❌ ffmpeg concatenation failed: {result.stderr}")
                if os.path.exists('list.txt'):
                    os.remove('list.txt')
            if not success:
                print("🔗 Falling back to moviepy for concatenation...")
                success = concatenate_with_moviepy(downloaded_files, output_file)
            if not success:
                print("❌ Concatenation failed. Using first video only.")
                os.rename(downloaded_files[0], output_file)
                downloaded_files = downloaded_files[1:]
            for fn in downloaded_files:
                if os.path.exists(fn):
                    os.remove(fn)
        if os.path.exists(output_file) and os.path.getsize(output_file) > 0:
            print(f"✅ Video ready: {output_file} ({format_size(os.path.getsize(output_file))})")
        else:
            print("❌ Failed to create final video file.")
    except Exception as e:
        print(f"❌ An error occurred: {str(e)}")
        for fn in downloaded_files:
            if os.path.exists(fn):
                os.remove(fn)
        if os.path.exists('list.txt'):
            os.remove('list.txt')
def progress_hook(d):
    if d['status'] == 'downloading':
        downloaded = d.get('downloaded_bytes', 0)
        total = d.get('total_bytes', d.get('total_bytes_estimate', 1000000))
        speed = d.get('speed', 0) or 0
        eta = d.get('eta', 0) or 0
        print(f"\r⬇️ File Progress: {draw_progress_bar(downloaded, total)} "
              f"({format_size(downloaded)}/{format_size(total)}) "
              f"Speed: {speed/(1024*1024):.2f} MB/s ETA: {format_time(eta)}", end='')
    elif d['status'] == 'finished':
        print("\r✅ File Download completed")
if __name__ == "__main__":
    if len(sys.argv) > 2:
        download_videos(sys.argv[1], sys.argv[2])
    else:
        print("Please provide a search query and output filename.")
EOF

cat << 'EOF' > pixabay_downloader.py
import requests
import os
import sys
import time
import random
import string
import subprocess
import shutil
try:
    from moviepy.editor import VideoFileClip, concatenate_videoclips
    MOVIEPY_AVAILABLE = True
except ImportError:
    MOVIEPY_AVAILABLE = False
def format_size(bytes_size):
    return f"{bytes_size/(1024*1024):.2f} MB"
def format_time(seconds):
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{mins:02d}:{secs:02d}"
def draw_progress_bar(progress, total, width=50):
    percent = progress / total * 100
    filled = int(width * progress // total)
    bar = '█' * filled + '-' * (width - filled)
    return f"[{bar}] {percent:.1f}%"
def check_ffmpeg():
    return shutil.which("ffmpeg") is not None
def concatenate_with_moviepy(files, output_file):
    if not MOVIEPY_AVAILABLE:
        print("❌ moviepy is not installed. Cannot concatenate with moviepy.")
        return False
    try:
        clips = []
        for fn in files:
            if os.path.exists(fn) and os.path.getsize(fn) > 0:
                try:
                    clip = VideoFileClip(fn)
                    clips.append(clip)
                except Exception as e:
                    print(f"⚠️ Skipping invalid file {fn}: {str(e)}")
        if not clips:
            print("❌ No valid video clips to concatenate.")
            return False
        final_clip = concatenate_videoclips(clips, method="compose")
        final_clip.write_videofile(output_file, codec="libx264", audio_codec="aac", temp_audiofile="temp-audio.m4a", remove_temp=True, threads=2)
        for clip in clips:
            clip.close()
        final_clip.close()
        return os.path.exists(output_file) and os.path.getsize(output_file) > 0
    except Exception as e:
        print(f"❌ Moviepy concatenation failed: {str(e)}")
        return False
def download_videos(query, output_file, target_size_mb=1000):
    api_key_file = os.path.expanduser('~/.pixabay_api_key')
    if not os.path.exists(api_key_file):
        print("❌ Pixabay API key file not found.")
        return
    with open(api_key_file, 'r') as f:
        api_key = f.read().strip()
    per_page = 100
    try:
        url = f"https://pixabay.com/api/videos/?key={api_key}&q={query}&per_page={per_page}&min_width=1920&min_height=1080&video_type=all"
        resp = requests.get(url, timeout=10)
        if resp.status_code != 200:
            print(f"❌ Error fetching Pixabay API: {resp.text}")
            return
        data = resp.json()
        videos = data.get('hits', [])
        if not videos:
            print("❌ No videos found for query.")
            return
        videos.sort(key=lambda x: x['duration'], reverse=True)
        downloaded_files = []
        total_size = 0
        total_downloaded = 0
        start_time = time.time()
        for i, v in enumerate(videos):
            video_url = v['videos'].get('large', {}).get('url') or v['videos'].get('medium', {}).get('url')
            if not video_url:
                continue
            filename = f"pix_{i}_{''.join(random.choices(string.ascii_letters + string.digits, k=8))}.mp4"
            print(f"🎬 Downloading video {i+1}: {v['tags']} ({v['duration']}s)")
            resp = requests.get(video_url, stream=True, timeout=10)
            size = int(resp.headers.get('content-length', 0))
            if size < 50 * 1024 * 1024:
                continue
            with open(filename, 'wb') as f:
                downloaded = 0
                for chunk in resp.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)
                        percent = downloaded / size * 100 if size else 0
                        speed = downloaded / (1024*1024 * (time.time() - start_time)) if (time.time() - start_time) > 0 else 0
                        eta = (size - downloaded) / (speed * 1024*1024) if speed > 0 else 0
                        print(f"\r⬇️ File Progress: {draw_progress_bar(downloaded, size)} "
                              f"({format_size(downloaded)}/{format_size(size)}) "
                              f"Speed: {speed:.2f} MB/s ETA: {format_time(eta)}", end='')
            print("\r✅ File Download completed")
            file_size = os.path.getsize(filename) if os.path.exists(filename) else 0
            if file_size == 0:
                if os.path.exists(filename):
                    os.remove(filename)
                continue
            total_size += file_size
            total_downloaded += file_size
            downloaded_files.append(filename)
            if total_size >= target_size_mb * 1024 * 1024:
                break
        if not downloaded_files:
            print("❌ No suitable videos downloaded.")
            return
        if len(downloaded_files) == 1:
            os.rename(downloaded_files[0], output_file)
        else:
            success = False
            if check_ffmpeg():
                print("🔗 Concatenating videos with ffmpeg...")
                with open('list.txt', 'w') as f:
                    for fn in downloaded_files:
                        f.write(f"file '{fn}'\n")
                result = subprocess.run(['ffmpeg', '-f', 'concat', '-safe', '0', '-i', 'list.txt', '-c', 'copy', output_file], capture_output=True, text=True)
                if result.returncode == 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                    success = True
                else:
                    print(f"❌ ffmpeg concatenation failed: {result.stderr}")
                if os.path.exists('list.txt'):
                    os.remove('list.txt')
            if not success:
                print("🔗 Falling back to moviepy for concatenation...")
                success = concatenate_with_moviepy(downloaded_files, output_file)
            if not success:
                print("❌ Concatenation failed. Using first video only.")
                os.rename(downloaded_files[0], output_file)
                downloaded_files = downloaded_files[1:]
            for fn in downloaded_files:
                if os.path.exists(fn):
                    os.remove(fn)
        if os.path.exists(output_file) and os.path.getsize(output_file) > 0:
            print(f"✅ Video ready: {output_file} ({format_size(os.path.getsize(output_file))})")
        else:
            print("❌ Failed to create final video file.")
    except Exception as e:
        print(f"❌ An error occurred: {str(e)}")
        for fn in downloaded_files:
            if os.path.exists(fn):
                os.remove(fn)
        if os.path.exists('list.txt'):
            os.remove('list.txt')
if __name__ == "__main__":
    if len(sys.argv) > 2:
        download_videos(sys.argv[1], sys.argv[2])
    else:
        print("Please provide a search query and output filename.")
EOF

cat << 'EOF' > pexels_downloader.py
import requests
import os
import sys
import time
import random
import string
import subprocess
import shutil
try:
    from moviepy.editor import VideoFileClip, concatenate_videoclips
    MOVIEPY_AVAILABLE = True
except ImportError:
    MOVIEPY_AVAILABLE = False
def format_size(bytes_size):
    return f"{bytes_size/(1024*1024):.2f} MB"
def format_time(seconds):
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{mins:02d}:{secs:02d}"
def draw_progress_bar(progress, total, width=50):
    percent = progress / total * 100
    filled = int(width * progress // total)
    bar = '█' * filled + '-' * (width - filled)
    return f"[{bar}] {percent:.1f}%"
def check_ffmpeg():
    return shutil.which("ffmpeg") is not None
def concatenate_with_moviepy(files, output_file):
    if not MOVIEPY_AVAILABLE:
        print("❌ moviepy is not installed. Cannot concatenate with moviepy.")
        return False
    try:
        clips = []
        for fn in files:
            if os.path.exists(fn) and os.path.getsize(fn) > 0:
                try:
                    clip = VideoFileClip(fn)
                    clips.append(clip)
                except Exception as e:
                    print(f"⚠️ Skipping invalid file {fn}: {str(e)}")
        if not clips:
            print("❌ No valid video clips to concatenate.")
            return False
        final_clip = concatenate_videoclips(clips, method="compose")
        final_clip.write_videofile(output_file, codec="libx264", audio_codec="aac", temp_audiofile="temp-audio.m4a", remove_temp=True, threads=2)
        for clip in clips:
            clip.close()
        final_clip.close()
        return os.path.exists(output_file) and os.path.getsize(output_file) > 0
    except Exception as e:
        print(f"❌ Moviepy concatenation failed: {str(e)}")
        return False
def download_videos(query, output_file, target_size_mb=1000):
    api_key_file = os.path.expanduser('~/.pexels_api_key')
    if not os.path.exists(api_key_file):
        print("❌ Pexels API key file not found.")
        return
    with open(api_key_file, 'r') as f:
        api_key = f.read().strip()
    per_page = 80
    try:
        headers = {'Authorization': api_key}
        url = f"https://api.pexels.com/videos/search?query={query}&per_page={per_page}&min_width=1920&min_height=1080"
        resp = requests.get(url, headers=headers, timeout=10)
        if resp.status_code != 200:
            print(f"❌ Error fetching Pexels API: {resp.text}")
            return
        data = resp.json()
        videos = data.get('videos', [])
        if not videos:
            print("❌ No videos found for query.")
            return
        videos.sort(key=lambda x: x['duration'], reverse=True)
        downloaded_files = []
        total_size = 0
        total_downloaded = 0
        start_time = time.time()
        for i, v in enumerate(videos):
            video_files = v.get('video_files', [])
            video_url = None
            for file in video_files:
                if file['width'] >= 1920 and file['height'] >= 1080:
                    video_url = file['link']
                    break
            if not video_url:
                continue
            filename = f"pex_{i}_{''.join(random.choices(string.ascii_letters + string.digits, k=8))}.mp4"
            print(f"🎬 Downloading video {i+1}: {v['id']} ({v['duration']}s)")
            resp = requests.get(video_url, stream=True, timeout=10)
            size = int(resp.headers.get('content-length', 0))
            if size < 50 * 1024 * 1024:
                continue
            with open(filename, 'wb') as f:
                downloaded = 0
                for chunk in resp.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)
                        percent = downloaded / size * 100 if size else 0
                        speed = downloaded / (1024*1024 * (time.time() - start_time)) if (time.time() - start_time) > 0 else 0
                        eta = (size - downloaded) / (speed * 1024*1024) if speed > 0 else 0
                        print(f"\r⬇️ File Progress: {draw_progress_bar(downloaded, size)} "
                              f"({format_size(downloaded)}/{format_size(size)}) "
                              f"Speed: {speed:.2f} MB/s ETA: {format_time(eta)}", end='')
            print("\r✅ File Download completed")
            file_size = os.path.getsize(filename) if os.path.exists(filename) else 0
            if file_size == 0:
                if os.path.exists(filename):
                    os.remove(filename)
                continue
            total_size += file_size
            total_downloaded += file_size
            downloaded_files.append(filename)
            if total_size >= target_size_mb * 1024 * 1024:
                break
        if not downloaded_files:
            print("❌ No suitable videos downloaded.")
            return
        if len(downloaded_files) == 1:
            os.rename(downloaded_files[0], output_file)
        else:
            success = False
            if check_ffmpeg():
                print("🔗 Concatenating videos with ffmpeg...")
                with open('list.txt', 'w') as f:
                    for fn in downloaded_files:
                        f.write(f"file '{fn}'\n")
                result = subprocess.run(['ffmpeg', '-f', 'concat', '-safe', '0', '-i', 'list.txt', '-c', 'copy', output_file], capture_output=True, text=True)
                if result.returncode == 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                    success = True
                else:
                    print(f"❌ ffmpeg concatenation failed: {result.stderr}")
                if os.path.exists('list.txt'):
                    os.remove('list.txt')
            if not success:
                print("🔗 Falling back to moviepy for concatenation...")
                success = concatenate_with_moviepy(downloaded_files, output_file)
            if not success:
                print("❌ Concatenation failed. Using first video only.")
                os.rename(downloaded_files[0], output_file)
                downloaded_files = downloaded_files[1:]
            for fn in downloaded_files:
                if os.path.exists(fn):
                    os.remove(fn)
        if os.path.exists(output_file) and os.path.getsize(output_file) > 0:
            print(f"✅ Video ready: {output_file} ({format_size(os.path.getsize(output_file))})")
        else:
            print("❌ Failed to create final video file.")
    except Exception as e:
        print(f"❌ An error occurred: {str(e)}")
        for fn in downloaded_files:
            if os.path.exists(fn):
                os.remove(fn)
        if os.path.exists('list.txt'):
            os.remove('list.txt')
if __name__ == "__main__":
    if len(sys.argv) > 2:
        download_videos(sys.argv[1], sys.argv[2])
    else:
        print("Please provide a search query and output filename.")
EOF

# Main execution loop with daily timer
while true; do
    # Wait for a random time between 12 AM and 11 PM next day (0 to 82800 seconds = 23 hours)
    sleep_time=$((RANDOM % 82801))
    echo -e "${BLUE}⏳ Waiting for $(($sleep_time / 3600)) hours $(($sleep_time % 3600 / 60)) minutes before starting today's uploads...${NC}"
    sleep $sleep_time

    echo -e "${GREEN}🚀 Starting daily video uploads at $(date)...${NC}"
    check_dependencies
    setup_pipe_path
    upload_videos
    cleanup
    echo -e "${GREEN}👋 Daily uploads completed at $(date). Waiting for next day...${NC}"

    # Sleep until the next day (ensure at least 24 hours from start)
    remaining_time=$((86400 - sleep_time))
    if [ $remaining_time -gt 0 ]; then
        echo -e "${BLUE}⏳ Sleeping for $(($remaining_time / 3600)) hours $(($remaining_time % 3600 / 60)) minutes until next day...${NC}"
        sleep $remaining_time
    fi
done
