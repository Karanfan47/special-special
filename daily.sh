#!/bin/bash

# Get the home directory and user
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    RUN_AS_USER="$SUDO_USER"
else
    USER_HOME="$HOME"
    RUN_AS_USER="$USER"
fi
#AAAAAAAAAAAAAAAA
# Cleanup temporary files
cleanup() {
    rm -f "$USER_HOME"/list.txt "$USER_HOME"/video_*.mp4 "$USER_HOME"/pix_*.mp4 "$USER_HOME"/pex_*.mp4 2>/dev/null
}

# Setup Python virtual environment
setup_venv() {
    VENV_DIR="$USER_HOME/pipe_venv"
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        source "$VENV_DIR/bin/activate"
        pip install --upgrade pip
        pip install yt-dlp requests moviepy
        deactivate
    fi
    chown -R "$RUN_AS_USER:$RUN_AS_USER" "$VENV_DIR"
}

# Setup pipe path
setup_pipe_path() {
    export PATH="$USER_HOME/.cargo/bin:$PATH"
    if [ -f "$USER_HOME/.cargo/env" ]; then
        source "$USER_HOME/.cargo/env"
    fi
}

# Create downloader scripts
setup_downloaders() {
    cat > "$USER_HOME/video_downloader.py" << 'INNER_EOF'
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
        return False
    try:
        clips = []
        for fn in files:
            if os.path.exists(fn) and os.path.getsize(fn) > 0:
                try:
                    clip = VideoFileClip(fn)
                    clips.append(clip)
                except Exception:
                    pass
        if not clips:
            return False
        final_clip = concatenate_videoclips(clips, method="compose")
        final_clip.write_videofile(output_file, codec="libx264", audio_codec="aac", temp_audiofile="temp-audio.m4a", remove_temp=True, threads=2)
        for clip in clips:
            clip.close()
        final_clip.close()
        return os.path.exists(output_file) and os.path.getsize(output_file) > 0
    except Exception:
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
                return
            for size, v in sorted(candidates, key=lambda x: -x[0]):
                if total_size + size <= target_size_mb * 1024 * 1024:
                    total_size += size
                    ydl.download([v['webpage_url']])
                    filename = ydl.prepare_filename(v)
                    if os.path.exists(filename) and os.path.getsize(filename) > 0:
                        downloaded_files.append(filename)
                        total_downloaded += size
            if not downloaded_files:
                return
            if len(downloaded_files) == 1:
                os.rename(downloaded_files[0], output_file)
            else:
                success = False
                if check_ffmpeg():
                    with open('list.txt', 'w') as f:
                        for fn in downloaded_files:
                            f.write(f"file '{fn}'\n")
                    result = subprocess.run(['ffmpeg', '-f', 'concat', '-safe', '0', '-i', 'list.txt', '-c', 'copy', output_file], capture_output=True, text=True)
                    if result.returncode == 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                        success = True
                    if os.path.exists('list.txt'):
                        os.remove('list.txt')
                if not success:
                    success = concatenate_with_moviepy(downloaded_files, output_file)
                if not success:
                    os.rename(downloaded_files[0], output_file)
                    downloaded_files = downloaded_files[1:]
                for fn in downloaded_files:
                    if os.path.exists(fn):
                        os.remove(fn)
    except Exception:
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
        print(f"\r⬇️ Progress: {draw_progress_bar(downloaded, total)} {format_size(downloaded)}/{format_size(total)} Speed: {speed/(1024*1024):.2f} MB/s ETA: {format_time(eta)}", end='')
    elif d['status'] == 'finished':
        print("\r✅ Download completed")

if __name__ == "__main__":
    if len(sys.argv) > 2:
        download_videos(sys.argv[1], sys.argv[2])
INNER_EOF
    chown "$RUN_AS_USER:$RUN_AS_USER" "$USER_HOME/video_downloader.py"

    cat > "$USER_HOME/pixabay_downloader.py" << 'INNER_EOF'
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
        return False
    try:
        clips = []
        for fn in files:
            if os.path.exists(fn) and os.path.getsize(fn) > 0:
                try:
                    clip = VideoFileClip(fn)
                    clips.append(clip)
                except Exception:
                    pass
        if not clips:
            return False
        final_clip = concatenate_videoclips(clips, method="compose")
        final_clip.write_videofile(output_file, codec="libx264", audio_codec="aac", temp_audiofile="temp-audio.m4a", remove_temp=True, threads=2)
        for clip in clips:
            clip.close()
        final_clip.close()
        return os.path.exists(output_file) and os.path.getsize(output_file) > 0
    except Exception:
        return False

def download_videos(query, output_file, target_size_mb=1000):
    api_key_file = os.path.expanduser('~/.pixabay_api_key')
    if not os.path.exists(api_key_file):
        return
    with open(api_key_file, 'r') as f:
        api_key = f.read().strip()
    per_page = 100
    try:
        url = f"https://pixabay.com/api/videos/?key={api_key}&q={query}&per_page={per_page}&min_width=1920&min_height=1080&video_type=all"
        resp = requests.get(url, timeout=10)
        if resp.status_code != 200:
            return
        data = resp.json()
        videos = data.get('hits', [])
        if not videos:
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
                        print(f"\r⬇️ Progress: {draw_progress_bar(downloaded, size)} {format_size(downloaded)}/{format_size(size)} Speed: {speed:.2f} MB/s ETA: {format_time(eta)}", end='')
            print("\r✅ Download completed")
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
            return
        if len(downloaded_files) == 1:
            os.rename(downloaded_files[0], output_file)
        else:
            success = False
            if check_ffmpeg():
                with open('list.txt', 'w') as f:
                    for fn in downloaded_files:
                        f.write(f"file '{fn}'\n")
                result = subprocess.run(['ffmpeg', '-f', 'concat', '-safe', '0', '-i', 'list.txt', '-c', 'copy', output_file], capture_output=True, text=True)
                if result.returncode == 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                    success = True
                if os.path.exists('list.txt'):
                    os.remove('list.txt')
            if not success:
                success = concatenate_with_moviepy(downloaded_files, output_file)
            if not success:
                os.rename(downloaded_files[0], output_file)
                downloaded_files = downloaded_files[1:]
            for fn in downloaded_files:
                if os.path.exists(fn):
                    os.remove(fn)
    except Exception:
        for fn in downloaded_files:
            if os.path.exists(fn):
                os.remove(fn)
        if os.path.exists('list.txt'):
            os.remove('list.txt')

if __name__ == "__main__":
    if len(sys.argv) > 2:
        download_videos(sys.argv[1], sys.argv[2])
INNER_EOF
    chown "$RUN_AS_USER:$RUN_AS_USER" "$USER_HOME/pixabay_downloader.py"

    cat > "$USER_HOME/pexels_downloader.py" << 'INNER_EOF'
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
        return False
    try:
        clips = []
        for fn in files:
            if os.path.exists(fn) and os.path.getsize(fn) > 0:
                try:
                    clip = VideoFileClip(fn)
                    clips.append(clip)
                except Exception:
                    pass
        if not clips:
            return False
        final_clip = concatenate_videoclips(clips, method="compose")
        final_clip.write_videofile(output_file, codec="libx264", audio_codec="aac", temp_audiofile="temp-audio.m4a", remove_temp=True, threads=2)
        for clip in clips:
            clip.close()
        final_clip.close()
        return os.path.exists(output_file) and os.path.getsize(output_file) > 0
    except Exception:
        return False

def download_videos(query, output_file, target_size_mb=1000):
    api_key_file = os.path.expanduser('~/.pexels_api_key')
    if not os.path.exists(api_key_file):
        return
    with open(api_key_file, 'r') as f:
        api_key = f.read().strip()
    per_page = 80
    try:
        headers = {'Authorization': api_key}
        url = f"https://api.pexels.com/videos/search?query={query}&per_page={per_page}&min_width=1920&min_height=1080"
        resp = requests.get(url, headers=headers, timeout=10)
        if resp.status_code != 200:
            return
        data = resp.json()
        videos = data.get('videos', [])
        if not videos:
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
                        print(f"\r⬇️ Progress: {draw_progress_bar(downloaded, size)} {format_size(downloaded)}/{format_size(size)} Speed: {speed:.2f} MB/s ETA: {format_time(eta)}", end='')
            print("\r✅ Download completed")
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
            return
        if len(downloaded_files) == 1:
            os.rename(downloaded_files[0], output_file)
        else:
            success = False
            if check_ffmpeg():
                with open('list.txt', 'w') as f:
                    for fn in downloaded_files:
                        f.write(f"file '{fn}'\n")
                result = subprocess.run(['ffmpeg', '-f', 'concat', '-safe', '0', '-i', 'list.txt', '-c', 'copy', output_file], capture_output=True, text=True)
                if result.returncode == 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 0:
                    success = True
                if os.path.exists('list.txt'):
                    os.remove('list.txt')
            if not success:
                success = concatenate_with_moviepy(downloaded_files, output_file)
            if not success:
                os.rename(downloaded_files[0], output_file)
                downloaded_files = downloaded_files[1:]
            for fn in downloaded_files:
                if os.path.exists(fn):
                    os.remove(fn)
    except Exception:
        for fn in downloaded_files:
            if os.path.exists(fn):
                os.remove(fn)
        if os.path.exists('list.txt'):
            os.remove('list.txt')

if __name__ == "__main__":
    if len(sys.argv) > 2:
        download_videos(sys.argv[1], sys.argv[2])
INNER_EOF
    chown "$RUN_AS_USER:$RUN_AS_USER" "$USER_HOME/pexels_downloader.py"
}

# Upload videos function
upload_videos() {
    setup_venv
    VENV_DIR="$USER_HOME/pipe_venv"
    source "$VENV_DIR/bin/activate"
    echo 'pexels: iur1f5KGwvSIR1xr8I1t3KR3NP88wFXeCyV12ibHnioNXQYTy95KhE69' > "$USER_HOME/.pexels_api_key"
    echo '51848865-07253475f9fc0309b02c38a39' > "$USER_HOME/.pixabay_api_key"
    chown "$RUN_AS_USER:$RUN_AS_USER" "$USER_HOME/.pexels_api_key" "$USER_HOME/.pixabay_api_key"
    num_uploads=$((RANDOM % 2 + 1))  # 1 or 2 uploads
    queries=(
        "nature scenery" "space galaxy" "ocean waves" "city night" "forest walk"
        "desert sunset" "mountain hike" "rainfall" "wild animals" "aurora borealis"
        "abstract art" "waterfall" "travel vlog" "street food" "night lights"
        "sunrise timelapse" "stars sky" "fireworks" "birds flying" "landscape view"
    )

    for ((i=1; i<=num_uploads; i++)); do
        sources=("youtube" "pixabay" "pexels")
        success=false
        query="${queries[$((RANDOM % ${#queries[@]}))]} full hd"
        for source in "${sources[@]}"; do
            random_suffix=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
            output_file="$USER_HOME/video_$random_suffix.mp4"
            download_success=false
            if [ "$source" = "youtube" ]; then
                python3 "$USER_HOME/video_downloader.py" "$query" "$output_file"
            elif [ "$source" = "pixabay" ]; then
                python3 "$USER_HOME/pixabay_downloader.py" "$query" "$output_file"
            elif [ "$source" = "pexels" ]; then
                python3 "$USER_HOME/pexels_downloader.py" "$query" "$output_file"
            fi
            if [ -f "$output_file" ] && [ $(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null) -gt 50000000 ]; then
                download_success=true
            fi
            if $download_success; then
                setup_pipe_path
                pipe upload-file "$output_file" "$output_file"
                if [ $? -eq 0 ]; then
                    link_output=$(pipe create-public-link "$output_file")
                    direct_link=$(echo "$link_output" | grep "Direct link" -A 1 | tail -n 1 | awk '{$1=$1};1')
                    social_link=$(echo "$link_output" | grep "Social media link" -A 1 | tail -n 1 | awk '{$1=$1};1')
                    file_id=$(echo "$link_output" | grep "File ID (Blake3)" | awk '{print $NF}')
                    if [ -n "$file_id" ]; then
                        if [ ! -f "$USER_HOME/file_details.json" ]; then
                            echo '[]' > "$USER_HOME/file_details.json"
                        fi
                        jq --arg fn "$output_file" --arg fid "$file_id" --arg dl "$direct_link" --arg sl "$social_link" \
                            '. + [{"file_name": $fn, "file_id": $fid, "direct_link": $dl, "social_link": $sl}]' \
                            "$USER_HOME/file_details.json" > "$USER_HOME/tmp.json" && mv "$USER_HOME/tmp.json" "$USER_HOME/file_details.json"
                        success=true
                    fi
                fi
                rm -f "$output_file"
            else
                rm -f "$output_file"
            fi
            if $success; then
                break
            fi
        done
    done
    deactivate
    cleanup
}

# Setup systemd service
setup_systemd_service() {
    if [ "$EUID" -ne 0 ]; then
        echo "This requires root privileges. Run with sudo."
        exit 1
    fi
    SERVICE_FILE="/etc/systemd/system/pipe-uploader.service"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Pipe Video Uploader Continuous Service
After=network.target

[Service]
Type=simple
User=$RUN_AS_USER
ExecStart=/bin/bash $USER_HOME/pipe-uploader.sh --run
WorkingDirectory=$USER_HOME
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable pipe-uploader.service
    systemctl start pipe-uploader.service
}

# Main execution
if [ "$1" == "--run" ]; then
    setup_downloaders
    while true; do
        upload_videos
        sleep_time=$((RANDOM % (12*3600) + 12*3600))  # 12-24 hours
        sleep $sleep_time
    done
else
    mv "$0" "$USER_HOME/pipe-uploader.sh"
    chown "$RUN_AS_USER:$RUN_AS_USER" "$USER_HOME/pipe-uploader.sh"
    chmod +x "$USER_HOME/pipe-uploader.sh"
    setup_downloaders
    setup_systemd_service
fi
