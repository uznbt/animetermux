#!/usr/bin/env python
import os
import sys
import time
import json
import sqlite3
import requests
import re
from bs4 import BeautifulSoup
import concurrent.futures
import shutil
import urllib.parse
import random

# Add backend directory to sys.path to easily import web_server
backend_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.append(backend_dir)
import web_server

# ANSI Color Codes
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
BLUE = "\033[94m"
CYAN = "\033[96m"
RESET = "\033[0m"
BOLD = "\033[1m"

# Global Thread Pools (50 Parallel Workers)
SCRAPE_EXECUTOR = concurrent.futures.ThreadPoolExecutor(max_workers=50)
UPLOAD_EXECUTOR = concurrent.futures.ThreadPoolExecutor(max_workers=50)

class RouteManager:
    def __init__(self, tokens, chat_ids):
        self.tokens = tokens
        self.chat_ids = chat_ids
        self.rate_limits_path = os.path.join(backend_dir, "cache", "rate_limits.json")
        self.lock = concurrent.futures.thread.threading.Lock()
        self._init_limits_file()
        
        # Keep an in-memory set of validated active routes for the current session
        self.session_valid_routes = set()
        
        # Verify routes dynamically at startup (Fast Parallel Check)
        self._verify_active_routes()

    def _init_limits_file(self):
        os.makedirs(os.path.dirname(self.rate_limits_path), exist_ok=True)
        if not os.path.exists(self.rate_limits_path):
            with open(self.rate_limits_path, "w") as f:
                json.dump({"rate_limits": {}, "bad_routes": []}, f)

    def _load_limits(self):
        try:
            with open(self.rate_limits_path, "r") as f:
                return json.load(f)
        except Exception:
            return {"rate_limits": {}, "bad_routes": []}

    def _save_limits(self, data):
        try:
            with open(self.rate_limits_path, "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"[RouteManager] Error saving limits: {e}")

    def _verify_active_routes(self):
        """Fast parallel dynamic verification of routes using sendChatAction."""
        print(f"\n{CYAN}[*] Memverifikasi rute chat aktif untuk caching...{RESET}")
        print(f"    Memeriksa {len(self.chat_ids)} Chat ID terhadap {len(self.tokens)} Bot secara paralel...")
        
        bot_valid_counts = {idx: 0 for idx in range(len(self.tokens))}
        
        def check_route(idx, token, cid):
            try:
                url = f"https://api.telegram.org/bot{token}/sendChatAction"
                resp = requests.post(url, json={"chat_id": cid, "action": "typing"}, timeout=3).json()
                if resp.get("ok"):
                    return idx, cid
            except Exception:
                pass
            return idx, None

        tasks = []
        for idx, token in enumerate(self.tokens):
            for cid in self.chat_ids:
                tasks.append((idx, token, cid))

        # Check all combinations concurrently at the exact same time
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(tasks)) as executor:
            futures = [executor.submit(check_route, idx, token, cid) for idx, token, cid in tasks]
            for future in concurrent.futures.as_completed(futures):
                idx, cid = future.result()
                if cid is not None:
                    bot_valid_counts[idx] += 1
                    self.session_valid_routes.add(f"{idx}:{cid}")

        for idx in range(len(self.tokens)):
            count = bot_valid_counts[idx]
            if count > 0:
                print(f"    {GREEN}✔ Bot-{idx} terhubung ke {count} chat.{RESET}")
            else:
                print(f"    {RED}✖ Bot-{idx} tidak terhubung ke chat mana pun! (Ketik /start ke bot ini){RESET}")
                
        if len(self.session_valid_routes) > 0:
            print(f"    {GREEN}Total rute upload tersedia: {len(self.session_valid_routes)}{RESET}\n")
        else:
            print(f"    {RED}WARNING: Tidak ada rute aktif! Caching latar belakang akan selalu gagal.{RESET}")
            print(f"    {YELLOW}Silakan jalankan /start pada setiap bot, atau masukkan bot ke grup.{RESET}\n")

    def get_valid_route(self):
        """Find a random route (bot_token, chat_id) that is validated, not bad, and not rate-limited."""
        with self.lock:
            data = self._load_limits()
            rate_limits = data.get("rate_limits", {})
            bad_routes = data.get("bad_routes", [])
            now = time.time()

            # Clean up expired rate limits
            active_limits = {}
            for route_str, limit_time in rate_limits.items():
                if now < limit_time:
                    active_limits[route_str] = limit_time
            if len(active_limits) != len(rate_limits):
                data["rate_limits"] = active_limits
                self._save_limits(data)

            # Filter possible routes using the dynamically validated session_valid_routes
            possible_routes = []
            for t_idx in range(len(self.tokens)):
                for c_id in self.chat_ids:
                    route_key = f"{t_idx}:{c_id}"
                    # Skip if it wasn't successfully verified at startup
                    if route_key not in self.session_valid_routes:
                        continue
                    if route_key in bad_routes:
                        continue
                    if route_key in active_limits:
                        continue
                    possible_routes.append((t_idx, c_id))

            if not possible_routes:
                # If all valid routes are temporarily rate-limited, fallback to the one expiring earliest
                fallback_routes = []
                for t_idx in range(len(self.tokens)):
                    for c_id in self.chat_ids:
                        route_key = f"{t_idx}:{c_id}"
                        if route_key in self.session_valid_routes and route_key not in bad_routes:
                            fallback_routes.append((t_idx, c_id))
                
                if not fallback_routes:
                    # In extreme fallback, pick a random validated one
                    if self.session_valid_routes:
                        route_key = random.choice(list(self.session_valid_routes))
                        t_idx, c_id = map(int, route_key.split(":"))
                        return t_idx, self.tokens[t_idx], str(c_id)
                    # Absolute emergency fallback
                    t_idx = random.randint(0, len(self.tokens) - 1)
                    c_id = random.choice(self.chat_ids)
                    return t_idx, self.tokens[t_idx], c_id
                
                # Pick the route with the minimum expiration time
                best_route = random.choice(fallback_routes)
                min_limit = float("inf")
                for r in fallback_routes:
                    r_key = f"{r[0]}:{r[1]}"
                    limit_val = active_limits.get(r_key, 0)
                    if limit_val < min_limit:
                        min_limit = limit_val
                        best_route = r
                t_idx, c_id = best_route
                return t_idx, self.tokens[t_idx], c_id

            # Pick a random valid route
            t_idx, c_id = random.choice(possible_routes)
            return t_idx, self.tokens[t_idx], c_id

    def mark_rate_limited(self, token_idx, chat_id, retry_after):
        """Mark a route as rate-limited until a certain timestamp."""
        with self.lock:
            data = self._load_limits()
            route_key = f"{token_idx}:{chat_id}"
            data["rate_limits"][route_key] = time.time() + retry_after
            self._save_limits(data)

    def mark_bad_route(self, token_idx, chat_id):
        """Mark a route as permanently invalid."""
        with self.lock:
            data = self._load_limits()
            route_key = f"{token_idx}:{chat_id}"
            if route_key not in data["bad_routes"]:
                data["bad_routes"].append(route_key)
            self._save_limits(data)

class ProgressTracker:
    def __init__(self):
        self.lock = concurrent.futures.thread.threading.Lock()
        self.total = 0
        self.completed = 0
        self.success_count = 0
        
    def add_total(self, count):
        with self.lock:
            self.total += count
            
    def increment(self, success=True):
        with self.lock:
            self.completed += 1
            if success:
                self.success_count += 1
            return self.completed, self.total

def get_terminal_width(max_width=60):
    try:
        cols = shutil.get_terminal_size().columns
        return min(cols - 2, max_width) if cols > 10 else max_width
    except Exception:
        return max_width

def print_separator(char="=", max_width=60):
    width = get_terminal_width(max_width)
    print(char * width)

def print_header(title, char="=", max_width=60):
    width = get_terminal_width(max_width)
    print("\n" + char * width)
    clean_title = title.upper()
    if len(clean_title) + 6 > width:
        print(clean_title)
    else:
        pad = (width - len(clean_title) - 2) // 2
        pad_str = char * pad
        print(f"{pad_str} {clean_title} {pad_str}")
    print(char * width)


def background_upload_single_image(url, route_manager, slug=None):
    """Custom cover uploader utilizing rate-limiting RouteManager."""
    if not route_manager:
        return
    tokens = route_manager.tokens
    chat_ids = route_manager.chat_ids
    if not tokens or not chat_ids:
        return
        
    try:
        # Check DB first
        conn = web_server.get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT file_id FROM anime_image_cache WHERE image_url=?", (url,))
        row = cursor.fetchone()
        conn.close()
        if row:
            temp_dir = os.path.join(backend_dir, "cache")
            ext = url.split('.')[-1].split('?')[0]
            if len(ext) > 4 or not ext:
                ext = 'jpg'
            temp_filename = web_server.encode_url_to_filename(url, ext)
            cover_path = os.path.join(temp_dir, temp_filename)
            if os.path.exists(cover_path):
                os.remove(cover_path)
            return
            
        # Download locally to temp dir
        temp_dir = os.path.join(backend_dir, "cache")
        os.makedirs(temp_dir, exist_ok=True)
        
        ext = url.split('.')[-1].split('?')[0]
        if len(ext) > 4 or not ext:
            ext = 'jpg'
            
        temp_filename = web_server.encode_url_to_filename(url, ext)
        cover_path = os.path.join(temp_dir, temp_filename)
        
        if not os.path.exists(cover_path):
            try:
                r = requests.get(url, headers={'User-Agent': 'Mozilla/5.0', 'Referer': web_server.BASE_URL}, timeout=15)
                if r.status_code != 200:
                    return
                with open(cover_path, "wb") as f:
                    f.write(r.content)
            except Exception:
                if os.path.exists(cover_path):
                    os.remove(cover_path)
                return

        # Multi-attempt upload using valid dynamic routes
        for attempt in range(5):
            token_idx, token, chat_id = route_manager.get_valid_route()
            
            payload = {
                "chat_id": chat_id,
                "disable_notification": True
            }
            
            try:
                with open(cover_path, "rb") as f:
                    upload_files = {
                        "document": (f"cover.{ext}", f, "application/octet-stream")
                    }
                    send_url = f"https://api.telegram.org/bot{token}/sendDocument"
                    resp = requests.post(send_url, data=payload, files=upload_files, timeout=30).json()
                    
                if resp.get("ok"):
                    file_id = resp["result"]["document"]["file_id"]
                    
                    # Delete message
                    msg_id = resp["result"]["message_id"]
                    try:
                        del_url = f"https://api.telegram.org/bot{token}/deleteMessage"
                        requests.post(del_url, data={"chat_id": chat_id, "message_id": msg_id}, timeout=5)
                    except Exception:
                        pass
                        
                    # Save to db cache mapping
                    conn = web_server.get_db_connection()
                    cursor = conn.cursor()
                    cursor.execute("INSERT OR REPLACE INTO anime_image_cache (image_url, file_id, updated_at) VALUES (?, ?, ?)", (url, file_id, time.time()))
                    conn.commit()
                    conn.close()
                    print(f"  [Telegram Upload] Successfully cached: {url} -> {file_id}")
                    break
                else:
                    err_desc = resp.get("description", "")
                    err_code = resp.get("error_code", 0)
                    
                    if err_code == 429:
                        # Extract rate limit time
                        retry_after = 30
                        try:
                            params = resp.get("parameters", {})
                            if "retry_after" in params:
                                retry_after = int(params["retry_after"])
                            else:
                                match = re.search(r'retry after (\d+)', err_desc.lower())
                                if match:
                                    retry_after = int(match.group(1))
                        except Exception:
                            pass
                        route_manager.mark_rate_limited(token_idx, chat_id, retry_after)
                        print(f"  [Telegram Upload] Route (Bot {token_idx} -> Chat {chat_id}) rate limited for {retry_after}s. Skipping route.")
                    elif any(word in err_desc.lower() for word in ["chat not found", "forbidden", "blocked", "chat_id_invalid", "deactivated"]):
                        route_manager.mark_bad_route(token_idx, chat_id)
                        print(f"  [Telegram Upload] Route (Bot {token_idx} -> Chat {chat_id}) marked permanently bad.")
                        
                    time.sleep(1)
            except Exception as e:
                time.sleep(1)
                
        # Clean up local file
        if os.path.exists(cover_path):
            try:
                os.remove(cover_path)
            except Exception:
                pass
    except Exception:
        pass

def preload_anime_detail(slug, route_manager):
    """Cache individual anime details and trigger covers upload asynchronously."""
    chat_ids = route_manager.chat_ids if route_manager else []
    try:
        db_entry = web_server.cache_manager.get_anime_detail(slug)
        if db_entry:
            return True, "DB Hit"
        
        url = urllib.parse.urljoin(web_server.BASE_URL, f"anime/{slug}/")
        html = web_server.fetch_html(url)
        data = web_server.parse_detail_html(html, slug)
        if data:
            web_server.cache_manager.set_anime_detail(slug, data)
            if data.get('thumb') and route_manager and chat_ids:
                # Asynchronous upload via separate pool
                UPLOAD_EXECUTOR.submit(background_upload_single_image, data['thumb'], route_manager, slug)
            return True, "Scraped & Cached"
        return False, "Failed to parse details"
    except Exception as e:
        return False, str(e)

def download_genre(genre_slug, genre_name, route_manager, only_details=False, reverse_pages=False):
    """Fetch all anime in a genre and preload details if requested."""
    print_header(f"GENRE: {genre_name} ({genre_slug})", char="-")
    
    # 1. Fetch semua halaman genre secara paralel sekaligus (50 halaman)
    anime_list = []
    MAX_PAGES = 50
    print(f"[*] Menjelajahi {MAX_PAGES} halaman genre secara paralel sekaligus...")

    def fetch_otaku_page(p):
        url = (f"https://otakudesu.blog/genres/{genre_slug}/"
               if p == 1 else
               f"https://otakudesu.blog/genres/{genre_slug}/page/{p}/")
        try:
            html = web_server.fetch_html(url)
            items = web_server.parse_genre_detail_html(html)
            return p, items or []
        except Exception:
            return p, []

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_PAGES) as page_exec:
        page_futures = {page_exec.submit(fetch_otaku_page, p): p for p in range(1, MAX_PAGES + 1)}
        page_results = {}
        for fut in concurrent.futures.as_completed(page_futures):
            p, items = fut.result()
            page_results[p] = items

    # Collect in order, stop at first empty page
    found_pages = 0
    for p in range(1, MAX_PAGES + 1):
        items = page_results.get(p, [])
        if not items:
            break
        anime_list.extend(items)
        found_pages += 1

    print(f"  [+] {found_pages} halaman Otakudesu berhasil dimuat.")

    # Deduplicate by slug preserving order
    seen_slugs = set()
    deduped_list = []
    for anime in anime_list:
        slug = anime.get('slug', '')
        if slug and slug not in seen_slugs:
            seen_slugs.add(slug)
            deduped_list.append(anime)
    anime_list = deduped_list

    if not anime_list:
        print(f"[-] Tidak ada anime ditemukan untuk genre {genre_name}!")
        return

    print(f"[+] Total anime unik ditemukan dalam genre: {len(anime_list)}")

    if only_details:
        DETAIL_WORKERS = 100
        print_separator(char="~")
        print(f"[*] Menjalankan Fast Cache Detail untuk {len(anime_list)} anime (Paralel {DETAIL_WORKERS})...")
        tracker = ProgressTracker()
        tracker.add_total(len(anime_list))

        def detail_task(anime):
            title = anime.get('title', 'Anime')
            slug = anime.get('slug', '')
            if not slug:
                tracker.increment(False)
                return
            success, msg = preload_anime_detail(slug, route_manager)
            completed, total = tracker.increment(success)
            percent = (completed / total) * 100
            color = GREEN if success else RED
            indicator = "[+]" if success else "[-]"
            print(f"  {indicator} [{completed}/{total}] {percent:.1f}% | {title} ({color}{msg}{RESET})")

        list_to_process = list(reversed(anime_list)) if reverse_pages else anime_list

        # Submit all tasks to a local 100-worker pool
        with concurrent.futures.ThreadPoolExecutor(max_workers=DETAIL_WORKERS) as detail_exec:
            futures = [detail_exec.submit(detail_task, anime) for anime in list_to_process]
            concurrent.futures.wait(futures)
                
        print_separator(char="~")
        print(f"[+] SELESAI PRA-UNDUH DETAIL GENRE {genre_name.upper()}!")
        print(f"    -> Berhasil: {tracker.success_count}/{tracker.total}")

def download_status_list(status_type, route_manager, reverse_pages=False):
    """Fetch all pages from ongoing/complete Otakudesu and preload full details + covers."""
    if status_type == "ongoing":
        label = "ONGOING ANIME"
        base_url = "https://otakudesu.blog/ongoing-anime/"
        page_url_fmt = "https://otakudesu.blog/ongoing-anime/page/{p}/"
    else:
        label = "COMPLETED ANIME"
        base_url = "https://otakudesu.blog/complete-anime/"
        page_url_fmt = "https://otakudesu.blog/complete-anime/page/{p}/"

    print_header(f"PRA-UNDUH {label} (DETAIL LENGKAP + THUMBNAIL)", char="=")

    MAX_PAGES = 50
    print(f"[*] Menjelajahi {MAX_PAGES} halaman {label} secara paralel sekaligus...")

    def fetch_page(p):
        url = base_url if p == 1 else page_url_fmt.format(p=p)
        try:
            html = web_server.fetch_html(url)
            return p, web_server.parse_paginated_list(html)
        except Exception:
            return p, []

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_PAGES) as page_exec:
        page_futures = {page_exec.submit(fetch_page, p): p for p in range(1, MAX_PAGES + 1)}
        page_results = {}
        for fut in concurrent.futures.as_completed(page_futures):
            p, items = fut.result()
            page_results[p] = items

    # Kumpulkan berurutan, stop di halaman pertama yang kosong
    anime_list = []
    found_pages = 0
    for p in range(1, MAX_PAGES + 1):
        items = page_results.get(p, [])
        if not items:
            break
        anime_list.extend(items)
        found_pages += 1

    print(f"  [+] {found_pages} halaman {label} berhasil dimuat.")

    # Deduplikasi berdasarkan slug
    seen_slugs = set()
    deduped = []
    for anime in anime_list:
        slug = anime.get('slug', '')
        if slug and slug not in seen_slugs:
            seen_slugs.add(slug)
            deduped.append(anime)
    anime_list = deduped

    if not anime_list:
        print(f"[-] Tidak ada anime ditemukan di halaman {label}!")
        return

    print(f"[+] Total anime unik ditemukan: {len(anime_list)}")

    DETAIL_WORKERS = 100
    print_separator(char="~")
    print(f"[*] Menjalankan Fast Cache Detail untuk {len(anime_list)} anime (Paralel {DETAIL_WORKERS})...")

    tracker = ProgressTracker()
    tracker.add_total(len(anime_list))

    def detail_task(anime):
        title = anime.get('title', 'Anime')
        slug = anime.get('slug', '')
        if not slug:
            tracker.increment(False)
            return
        success, msg = preload_anime_detail(slug, route_manager)
        completed, total = tracker.increment(success)
        percent = (completed / total) * 100
        color = GREEN if success else RED
        indicator = "[+]" if success else "[-]"
        print(f"  {indicator} [{completed}/{total}] {percent:.1f}% | {title} ({color}{msg}{RESET})")

    list_to_process = list(reversed(anime_list)) if reverse_pages else anime_list

    with concurrent.futures.ThreadPoolExecutor(max_workers=DETAIL_WORKERS) as detail_exec:
        futures = [detail_exec.submit(detail_task, anime) for anime in list_to_process]
        concurrent.futures.wait(futures)

    print_separator(char="~")
    print(f"[+] SELESAI PRA-UNDUH {label}!")
    print(f"    -> Berhasil: {tracker.success_count}/{tracker.total}")


def main():
    args = sys.argv[1:]
    
    reverse_pages = False
    if "-f" in args:
        reverse_pages = True
        args = [a for a in args if a != "-f"]
        
    only_details = False
    if "--detail" in args or "-d" in args:
        only_details = True
        args = [a for a in args if a != "--detail" and a != "-d"]

    # Parse -ongoing / -complete
    status_mode = None
    if "-ongoing" in args:
        status_mode = "ongoing"
        args = [a for a in args if a != "-ongoing"]
    elif "-complete" in args:
        status_mode = "complete"
        args = [a for a in args if a != "-complete"]

    if not args and status_mode is None:
        print(f"{BOLD}{BLUE}=== ANIME WEB READER CACHE PRELOADER ==={RESET}")
        print("Penggunaan:")
        print("  python backend/preloader.py --genre <genre-slug> [-f] [-d]")
        print("  python backend/preloader.py --anime <anime-slug>")
        print("  python backend/preloader.py --all [-f] [-d]        (Seluruh genre)")
        print("  python backend/preloader.py --downloadgenre -ongoing [-f]  (Seluruh Ongoing)")
        print("  python backend/preloader.py --downloadgenre -complete [-f] (Seluruh Completed)")
        sys.exit(1)

    cmd = args[0]
    
    if os.environ.get('SKIP_TELEGRAM') == 'true':
        tokens = []
        chat_ids = []
        route_manager = None
        print(f"{YELLOW}[*] Mode Hotlink Aktif (SKIP_TELEGRAM=true). Pengunggahan ke Telegram dilewati.{RESET}")
    else:
        tokens = web_server.load_bot_tokens()
        chat_ids = web_server.load_chat_ids()
        route_manager = None
        if tokens and chat_ids:
            route_manager = RouteManager(tokens, chat_ids)
        else:
            print("[!] Warning: BOT_TOKEN atau Chat ID tidak ditemukan.")
            print("[!] Cover baru akan disimpan sebagai cache lokal, pengunggahan Telegram dilewati.")
    
    if cmd == "--all" or cmd == "--downloadgenre":
        # -ongoing / -complete mode
        if status_mode:
            if os.environ.get('SKIP_TELEGRAM') == 'true':
                tokens = []
                chat_ids = []
                route_manager = None
            else:
                tokens = web_server.load_bot_tokens()
                chat_ids = web_server.load_chat_ids()
                route_manager = None
                if tokens and chat_ids:
                    route_manager = RouteManager(tokens, chat_ids)
                else:
                    print("[!] Warning: BOT_TOKEN atau Chat ID tidak ditemukan.")
            download_status_list(status_mode, route_manager, reverse_pages=reverse_pages)
            # Wait for uploads done in download_status_list, jump to shutdown
            if route_manager:
                print(f"\n{CYAN}[*] Menunggu seluruh sisa pengunggahan cover Telegram selesai (Paralel 50)...{RESET}")
            UPLOAD_EXECUTOR.shutdown(wait=True)
            SCRAPE_EXECUTOR.shutdown(wait=True)
            print(f"{GREEN}[+] Semua proses caching & upload selesai secara aman.{RESET}")
            return

        print_header("PRA-UNDUH SELURUH GENRE ANIME")

        def fetch_genres():
            url = "https://otakudesu.blog/genre-list/"
            html = web_server.fetch_html(url)
            return web_server.parse_genres_html(html)

        genres, _ = web_server.cache_manager.get_data_swr("genres", fetch_genres, ttl_seconds=86400)

        filtered_genres = [g for g in genres if g.get('slug')]

        print(f"[*] Ditemukan {len(filtered_genres)} genre untuk di-cache.")

        for idx, g in enumerate(filtered_genres):
            name = g.get('name')
            slug = g.get('slug')
            print(f"\n[*] [{idx+1}/{len(filtered_genres)}] Memulai genre: {BOLD}{name}{RESET}")
            download_genre(slug, name, route_manager, only_details=only_details, reverse_pages=reverse_pages)

        print_header("PRA-UNDUH SELURUH GENRE ANIME SELESAI!", char="*")
        
    elif cmd == "--genre" and len(args) > 1:
        genre_slug = args[1].lower()
        display_name = genre_slug.title()
        download_genre(genre_slug, display_name, route_manager, only_details=only_details, reverse_pages=reverse_pages)
        
    elif cmd == "--anime" and len(args) > 1:
        anime_slug = args[1]
        print(f"[*] Melakukan Fast Cache Detail Anime: {anime_slug}...")
        success, msg = preload_anime_detail(anime_slug, route_manager)
        if success:
            print(f"{GREEN}[+] Sukses: {msg}{RESET}")
        else:
            print(f"{RED}[-] Gagal: {msg}{RESET}")
            
    else:
        if cmd.startswith("--"):
            clean_cmd = cmd[2:].lower()
            download_genre(clean_cmd, clean_cmd.title(), route_manager, only_details=only_details, reverse_pages=reverse_pages)
        else:
            print(f"{RED}[-] Argument tidak dikenali.{RESET}")
            sys.exit(1)

    # Wait for all background Telegram uploads to fully complete before exiting
    if route_manager:
        print(f"\n{CYAN}[*] Menunggu seluruh sisa pengunggahan cover Telegram selesai (Paralel 50)...{RESET}")
    UPLOAD_EXECUTOR.shutdown(wait=True)
    SCRAPE_EXECUTOR.shutdown(wait=True)
    print(f"{GREEN}[+] Semua proses caching & upload selesai secara aman.{RESET}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{RED}[-] Proses dibatalkan oleh pengguna (KeyboardInterrupt).{RESET}")
        try:
            UPLOAD_EXECUTOR.shutdown(wait=False, cancel_futures=True)
            SCRAPE_EXECUTOR.shutdown(wait=False, cancel_futures=True)
        except Exception:
            pass
        sys.exit(0)
