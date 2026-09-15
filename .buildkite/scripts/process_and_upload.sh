#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "📦 Installing system dependencies..."
if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq aria2 python3 python3-requests python3-pip curl >/dev/null
else
    apt-get update -qq
    apt-get install -y -qq aria2 python3 python3-requests python3-pip curl >/dev/null
fi

pip3 install --break-system-packages magnet2torrent requests || pip3 install magnet2torrent requests || true

echo "🧲 Converting magnets to torrents..."
mkdir -p downloads torrents

python3 - << 'EOF'
import asyncio
import os
import requests
from magnet2torrent import Magnet2Torrent, FailedToFetchException

link_url = "https://pink-script-snap.lovable.app/api/public/page/e625b079-9246-4bd1-9626-c7c2fe3142a0.txt"

async def main():
    try:
        ks = requests.get(link_url, timeout=10).text
        if "STOP.ALL.TORRENTS" in ks:
            print("🛑 Global kill switch active.")
            return
            
        for link in ks.splitlines():
            link = link.strip()
            if link and not link.startswith('#') and not link.endswith(' NO'):
                if link.startswith('magnet:'):
                    print(f"📥 Converting magnet using magnet2torrent: {link[:50]}...", flush=True)
                    try:
                        m2t = Magnet2Torrent(link)
                        filename, torrent_data = await m2t.retrieve_torrent()
                        torrent_path = os.path.join("torrents", f"{filename}.torrent")
                        with open(torrent_path, "wb") as f:
                            f.write(torrent_data)
                        print(f"✅ Saved torrent: {torrent_path}")
                    except FailedToFetchException:
                        print(f"❌ Failed to fetch metadata for magnet link.")
                elif link.startswith('http'):
                    tor_data = requests.get(link).content
                    with open('torrents/temp.torrent', 'wb') as tf:
                        tf.write(tor_data)
                    print("✅ Downloaded direct .torrent file.")
    except Exception as e:
        print(f"Error processing links: {e}")

asyncio.run(main())
EOF

echo "🚀 Starting concurrent aria2c downloads..."
python3 - << 'EOF'
import os
import glob
import asyncio

async def download_torrent(torrent_file, sem, max_retries=3):
    trackers = "udp://tracker.openbittorrent.com:80/announce,udp://tracker.opentrackr.org:1337/announce,udp://tracker.torrent.eu.org:451/announce,udp://exodus.desync.com:6969/announce"
    
    async with sem:
        for attempt in range(1, max_retries + 1):
            print(f"📥 [Attempt {attempt}/{max_retries}] Starting: {torrent_file}")
            cmd = [
                "aria2c",
                "--console-log-level=warn",
                "--summary-interval=0",
                "--dir=downloads",
                "--seed-time=0",
                "--bt-stop-timeout=60",
                "--timeout=60",
                "--enable-dht=true",
                "--enable-peer-exchange=true",
                "--follow-torrent=mem",
                f"--bt-tracker={trackers}",
                torrent_file
            ]
            
            proc = await asyncio.create_subprocess_exec(*cmd)
            await proc.communicate()
            
            if proc.returncode == 0:
                print(f"✅ Successfully finished: {torrent_file}")
                return torrent_file
            else:
                print(f"⚠️ Timeout/Error on {torrent_file} (Attempt {attempt}). Cleaning control files and re-adding...")
                control_file = f"downloads/{os.path.basename(torrent_file)}.aria2"
                if os.path.exists(control_file):
                    os.remove(control_file)
        
        print(f"❌ Failed all {max_retries} attempts for: {torrent_file}")
        return None

async def main():
    torrents = glob.glob("torrents/*.torrent")
    if not torrents:
        print("⚠️ No torrent files found to download.")
        return

    os.makedirs("downloads", exist_ok=True)
    sem = asyncio.Semaphore(8)
    
    tasks = [download_torrent(t, sem) for t in torrents]
    results = await asyncio.gather(*tasks)
    finished = [r for r in results if r]
    
    print("\n====================")
    print("🎉 FINISHED DOWNLOADS:")
    print("====================")
    for item in finished:
        print(f"✅ {item}")
    print("====================\n")

asyncio.run(main())
EOF

echo "📂 Applying custom folder grouping rules..."
python3 - << 'EOF'
import os, shutil, re
from datetime import date
from collections import defaultdict

folder = "downloads"
video_ext = ('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v')
sub_ext = ('.srt', '.ass', '.vtt', '.sub')
archive_ext = ('.zip', '.rar', '.7z', '.tar', '.gz')
today_date = date.today().strftime("%Y-%m-%d")

def move_with_subtitles(file_path, target_folder):
    os.makedirs(target_folder, exist_ok=True)
    dst_path = os.path.join(target_folder, os.path.basename(file_path))
    if file_path != dst_path and os.path.exists(file_path):
        shutil.move(file_path, dst_path)
    
    base_stem = os.path.splitext(file_path)[0]
    for s_ext in sub_ext:
        sub_file = base_stem + s_ext
        if os.path.exists(sub_file):
            sub_dst = os.path.join(target_folder, os.path.basename(sub_file))
            if sub_file != sub_dst:
                shutil.move(sub_file, sub_dst)

for r, _, files in os.walk(folder):
    for f in files:
        if f.lower().endswith(archive_ext):
            arc_path = os.path.join(r, f)
            stem = os.path.splitext(f)[0]
            target_dir = os.path.join(folder, stem)
            if os.path.dirname(arc_path) != target_dir:
                move_with_subtitles(arc_path, target_dir)

protected_dirs = set()
if os.path.exists(folder):
    for item in os.listdir(folder):
        item_path = os.path.join(folder, item)
        if os.path.isdir(item_path):
            vids = [
                os.path.join(r, f) for r, _, files in os.walk(item_path)
                for f in files if f.lower().endswith(video_ext)
            ]
            if len(vids) > 3:
                print(f"🔒 Keeping existing nested folder intact (>3 videos): {item}")
                protected_dirs.add(item_path)

remaining_videos = []
for r, _, files in os.walk(folder):
    if any(r.startswith(p_dir) for p_dir in protected_dirs):
        continue
    for f in files:
        if f.lower().endswith(video_ext):
            remaining_videos.append(os.path.join(r, f))

series_regex = re.compile(r'(?i)^(.*?)[.\s_-]+S(\d{1,2})(?:[EX\-]|\b)')
def clean_series_name(raw_name):
    return re.sub(r'(?i)(www\.[^\s]+\s*-\s*|^\[.*?\]\s*)', '', raw_name).strip('. -_')

series_groups = defaultdict(list)
movies = []

for vid_path in remaining_videos:
    vid_name = os.path.basename(vid_path)
    parent_name = os.path.basename(os.path.dirname(vid_path))
    match = series_regex.search(vid_name) or series_regex.search(parent_name)
    if match:
        s_name = clean_series_name(match.group(1))
        s_num = match.group(2)
        group_key = f"{s_name.lower()}_S{s_num}"
        series_groups[group_key].append(vid_path)
    else:
        movies.append(vid_path)

for group_key, vids in series_groups.items():
    if len(vids) > 3:
        first_stem = os.path.splitext(os.path.basename(vids[0]))[0]
        target_dir = os.path.join(folder, first_stem)
        for v in vids:
            move_with_subtitles(v, target_dir)
    else:
        date_dir = os.path.join(folder, today_date)
        for v in vids:
            move_with_subtitles(v, date_dir)

for m in movies:
    stem = os.path.splitext(os.path.basename(m))[0]
    movie_dir = os.path.join(folder, stem)
    move_with_subtitles(m, movie_dir)

for r, dirs, files in os.walk(folder, topdown=False):
    if r == folder or any(r.startswith(p_dir) for p_dir in protected_dirs):
        continue
    if not os.listdir(r):
        os.rmdir(r)
EOF

echo "📤 Uploading Folders to Gofile..."
python3 - << 'EOF'
import os
import json
import subprocess
import requests

GOFILE_TOKEN = os.environ.get("GOFILE_TOKEN", "VoTnBsgTAiTqm97X6FmvdmBswsMPl6SG")
ROOT_FOLDER_ID = os.environ.get("ROOT_FOLDER_ID", "51130d09-efd5-48a9-97e4-35e2c21a6cde")
FOLDER_PATH = 'downloads'

summary_links = []
headers = {"Authorization": f"Bearer {GOFILE_TOKEN}"} if GOFILE_TOKEN else {}

# 1. Retrieve active upload server
try:
    srv_res = requests.get("https://api.gofile.io/servers", headers=headers, timeout=10).json()
    if srv_res.get("status") == "ok" and srv_res['data']['servers']:
        SERVER = srv_res['data']['servers'][0]['name']
    else:
        raise Exception("Could not retrieve active Gofile server.")
except Exception as e:
    print(f"❌ Failed to fetch Gofile server: {e}")
    exit(1)

def create_gofile_folder(parent_id, folder_name):
    url = "https://api.gofile.io/contents/createFolder"
    payload = {"parentFolderId": parent_id, "folderName": folder_name}
    try:
        res = requests.post(url, json=payload, headers=headers, timeout=15)
        data = res.json()
        if data.get("status") == "ok":
            return data['data']['id'], data['data'].get('downloadPage')
    except Exception as e:
        print(f"⚠️ API folder creation error: {e}")
    return None, None

def upload_to_gofile(file_path, folder_id=None):
    url = f"https://{SERVER}.gofile.io/contents/uploadfile"
    data = {}
    if folder_id:
        data['folderId'] = folder_id

    try:
        with open(file_path, 'rb') as f:
            files = {'file': f}
            res = requests.post(url, data=data, files=files, headers=headers, timeout=3600)
            return res.json()
    except json.decoder.JSONDecodeError:
        print(f"❌ Server returned invalid response (HTTP {res.status_code}): {res.text[:150]}")
        return {"status": "error", "error": f"HTTP {res.status_code}"}
    except requests.exceptions.RequestException as e:
        print(f"❌ Network/Request error during upload: {e}")
        return {"status": "error", "error": str(e)}

if os.path.exists(FOLDER_PATH):
    for item in os.listdir(FOLDER_PATH):
        item_path = os.path.join(FOLDER_PATH, item)
        
        if os.path.isdir(item_path):
            print(f"\n📁 Processing local folder: {item}")
            gofile_folder_id = None
            gofile_url = None
            
            if ROOT_FOLDER_ID:
                gofile_folder_id, gofile_url = create_gofile_folder(ROOT_FOLDER_ID, item)
            
            for root, _, files in os.walk(item_path):
                for filename in files:
                    if any(x in filename for x in [".!qB", ".part", ".aria2"]):
                        continue
                    file_path = os.path.join(root, filename)
                    file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
                    print(f"  ⬆️ Uploading: {filename} ({file_size_mb:.2f} MB)")
                    
                    res = upload_to_gofile(file_path, folder_id=gofile_folder_id)
                    if res.get("status") == "ok":
                        data = res.get("data", {})
                        if not gofile_folder_id:
                            gofile_folder_id = data.get("parentFolder")
                            gofile_url = data.get("downloadPage")
                        print(f"  ✅ Uploaded {filename}")
                    else:
                        print(f"  ❌ Failed uploading {filename}: {res.get('error', res)}")
            
            if gofile_url:
                print(f"🔗 Folder Link: {gofile_url}")
                summary_links.append(f"* **{item}**: {gofile_url}")

        elif os.path.isfile(item_path):
            if any(x in item for x in [".!qB", ".part", ".aria2"]):
                continue
            file_size_mb = os.path.getsize(item_path) / (1024 * 1024)
            print(f"\n⬆️ Uploading file: {item} ({file_size_mb:.2f} MB)")
            res = upload_to_gofile(item_path, folder_id=ROOT_FOLDER_ID if ROOT_FOLDER_ID else None)
            if res.get("status") == "ok":
                data = res.get("data", {})
                url = data.get('downloadPage')
                print(f"🔗 File Link: {url}")
                summary_links.append(f"* **{item}**: {url}")

if summary_links:
    markdown_body = "### 📦 Generated Gofile Links\n\n" + "\n".join(summary_links)
    try:
        subprocess.run([
            "buildkite-agent", "annotate", markdown_body,
            "--style", "success",
            "--context", "gofile-results"
        ], check=False)
    except Exception:
        pass
EOF
