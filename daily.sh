#!/bin/bash

# Initialize tput for color and formatting
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0)
    BOLD=$(tput bold)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
    BOLD=""
fi

# Ensure script runs with sudo
if [ "$EUID" -ne 0 ]; then
    echo "${RED}${BOLD}❌ This script requires root privileges. Please run with sudo.${NC}"
    exit 1
fi

# Cleanup temporary files
cleanup() {
    echo "${BLUE}${BOLD}🧹 Cleaning up temporary files...${NC}"
    rm -f list.txt video_*.mp4 pix_*.mp4 pex_*.mp4 2>/dev/null
}

# Setup Python virtual environment if not exists
setup_venv() {
    VENV_DIR="$HOME/pipe_venv"
    if [ ! -d "$VENV_DIR" ]; then
        echo "${BLUE}${BOLD}🛠️ Setting up Python virtual environment at $VENV_DIR...${NC}"
        python3 -m venv "$VENV_DIR"
        source "$VENV_DIR/bin/activate"
        pip install --upgrade pip
        pip install yt-dlp requests moviepy
        deactivate
    fi
}

# Setup pipe path if needed
setup_pipe_path() {
    export PATH=$HOME/.cargo/bin:$PATH
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    fi
}

# Create downloader scripts
setup_downloaders() {
    echo "${BLUE}${BOLD}📝 Creating downloader scripts...${NC}"
    cat > "$HOME/video_downloader.py" << 'INNER_EOF'
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
INNER_EOF

    cat > "$HOME/pixabay_downloader.py" << 'INNER_EOF'
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
INNER_EOF

    cat > "$HOME/pexels_downloader.py" << 'INNER_EOF'
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
INNER_EOF
}

# Upload videos function
upload_videos() {
    setup_venv
    VENV_DIR="$HOME/pipe_venv"
    source "$VENV_DIR/bin/activate"
    echo 'pexels: iur1f5KGwvSIR1xr8I1t3KR3NP88wFXeCyV12ibHnioNXQYTy95KhE69' > "$HOME/.pexels_api_key"
    echo '51848865-07253475f9fc0309b02c38a39' > "$HOME/.pixabay_api_key"
    num_uploads=$((RANDOM % 3 + 5))
    echo "${GREEN}${BOLD}📦 Number of uploads set to: $num_uploads${NC}"

    queries=(
        "nature scenery" "space galaxy" "ocean waves" "city night" "forest walk"
        "desert sunset" "mountain hike" "rainfall" "wild animals" "aurora borealis"
        "abstract art" "waterfall" "travel vlog" "street food" "night lights"
        "sunrise timelapse" "stars sky" "fireworks" "birds flying" "landscape view"
        "cyberpunk city" "underwater" "ancient ruins" "snowfall" "cloud timelapse"
        "lava volcano" "river flowing" "beach waves" "storm clouds" "time lapse"
        "camping nature" "urban exploration" "slow motion" "cinematic b-roll"
        "travel nature" "extreme sports" "surfing ocean" "skydiving" "fishing river"
        "cultural festival" "street dance" "graffiti art" "skyscrapers" "jungle life"
        "desert safari" "road trip" "forest animals" "temple ruins" "bridge view"
        "train journey" "island view" "space rocket" "milky way" "snow mountains"
        "valley drone" "night drone" "desert drone" "city drone" "river drone"
        "urban cityscape" "foggy morning" "rainforest" "wild safari" "tropical island"
        "storm timelapse" "festival lights" "street market" "street performance"
        "sky clouds" "mountain top" "flying drone" "forest drone" "cave exploration"
        "ice glacier" "sunset beach" "colorful lights" "abstract motion" "ocean diving"
        "night traffic" "festival parade" "city skyline" "campfire night" "wild jungle"
        "forest sunset" "water stream" "northern lights" "dolphins swimming" "coral reef"
        "hot air balloon" "plane takeoff" "temple ceremony" "monsoon rain" "countryside"
        "street timelapse" "market bazaar" "architecture" "technology abstract"
        "flower field" "wild horses" "deep space" "storm lightning" "lakeside view"
    )

    for ((i=1; i<=num_uploads; i++)); do
        echo "${BLUE}${BOLD}📹 Starting upload $i/$num_uploads...${NC}"
        sources=("youtube" "pixabay" "pexels")
        success=false
        query="${queries[$((RANDOM % ${#queries[@]}))]} full hd"
        for source in "${sources[@]}"; do
            echo "${YELLOW}${BOLD}🔍 Trying $source with query '$query'...${NC}"
            random_suffix=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
            output_file="video_$random_suffix.mp4"
            download_success=false
            if [ "$source" = "youtube" ]; then
                python3 "$HOME/video_downloader.py" "$query" "$output_file" 2>&1
            elif [ "$source" = "pixabay" ]; then
                python3 "$HOME/pixabay_downloader.py" "$query" "$output_file" 2>&1
            elif [ "$source" = "pexels" ]; then
                python3 "$HOME/pexels_downloader.py" "$query" "$output_file" 2>&1
            fi
            if [ -f "$output_file" ] && [ $(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null) -gt 50000000 ]; then
                download_success=true
            fi
            if $download_success; then
                echo "${BLUE}${BOLD}⬆️ Uploading video from $source...${NC}"
                setup_pipe_path
                upload_output=$(pipe upload-file "$output_file" "$output_file" 2>&1)
                echo "$upload_output"
                if [ $? -eq 0 ]; then
                    file_id=$(echo "$upload_output" | grep "File ID (Blake3)" | awk '{print $NF}')
                    link_output=$(pipe create-public-link "$output_file" 2>&1)
                    echo "$link_output"
                    direct_link=$(echo "$link_output" | grep "Direct link" -A 1 | tail -n 1 | awk '{$1=$1};1')
                    social_link=$(echo "$link_output" | grep "Social media link" -A 1 | tail -n 1 | awk '{$1=$1};1')
                    if [ -n "$file_id" ]; then
                        if [ ! -f "file_details.json" ]; then
                            echo '[]' > file_details.json
                        fi
                        jq --arg fn "$output_file" --arg fid "$file_id" --arg dl "$direct_link" --arg sl "$social_link" \
                            '. + [{"file_name": $fn, "file_id": $fid, "direct_link": $dl, "social_link": $sl}]' \
                            file_details.json > tmp.json && mv tmp.json file_details.json
                        if [ $? -eq 0 ]; then
                            echo "${GREEN}${BOLD}✅ Upload $i successful from $source.${NC}"
                            success=true
                        else
                            echo "${RED}${BOLD}❌ Failed to save file details for upload $i.${NC}"
                        fi
                    else
                        echo "${RED}${BOLD}❌ Failed to extract File ID for upload $i.${NC}"
                    fi
                else
                    echo "${RED}${BOLD}❌ Upload failed: $upload_output${NC}"
                fi
                rm -f "$output_file"
            else
                echo "${RED}${BOLD}❌ Download failed or file too small from $source.${NC}"
                rm -f "$output_file"
            fi
            if $success; then
                break
            fi
        done
        if ! $success; then
            echo "${RED}${BOLD}❌ Upload $i failed from all sources.${NC}"
        fi
    done
    deactivate
    cleanup
}

# Setup systemd service
setup_systemd_service() {
    echo "${BLUE}${BOLD}⚙️ Setting up systemd service...${NC}"
    SERVICE_FILE="/etc/systemd/system/pipe-uploader.service"
    USER=$(logname)
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Pipe Video Uploader Continuous Service
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=/bin/bash $HOME/pipe-uploader.sh --run
WorkingDirectory=$HOME
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable pipe-uploader.service
    systemctl start pipe-uploader.service
    echo "${GREEN}${BOLD}✅ Systemd service 'pipe-uploader' set up and started.${NC}"
    systemctl status pipe-uploader.service
}

# Main execution
if [ "$1" == "--run" ]; then
    setup_downloaders
    while true; do
        echo "${BLUE}${BOLD}🕒 Starting new upload cycle at $(date)...${NC}"
        upload_videos
        sleep_time=$((RANDOM % (8*3600) + 20*3600))
        hours=$((sleep_time / 3600))
        echo "${BLUE}${BOLD}⏳ Sleeping for $hours hours before next upload session...${NC}"
        sleep $sleep_time
    done
else
    setup_downloaders
    setup_systemd_service
fi
