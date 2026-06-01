import os
import re
import json
import time
import random
import sqlite3
import urllib.parse
import threading
import base64
import io
import concurrent.futures
from flask import Flask, jsonify, request, Response, send_from_directory, send_file, redirect
import flask.cli
flask.cli.show_server_banner = lambda *args: None

from flask_cors import CORS
import requests
from bs4 import BeautifulSoup

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATIC_FOLDER = os.path.join(BASE_DIR, 'frontend/dist')

app = Flask(__name__)
CORS(app)  # Enable CORS for frontend requests

DB_PATH = os.path.join(os.path.dirname(__file__), "cache.db")
DB_WRITE_LOCK = threading.Lock()

def get_db_connection(db_path=DB_PATH):
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=30000")
    except Exception:
        pass
    return conn
BASE_URL = "https://otakudesu.blog/"
AJAX_URL = "https://otakudesu.blog/wp-admin/admin-ajax.php"

USER_AGENTS = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15',
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
]

def get_headers(referer=None):
    headers = {
        'User-Agent': random.choice(USER_AGENTS),
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.5',
    }
    if referer:
        headers['Referer'] = referer
    else:
        headers['Referer'] = BASE_URL
    return headers

# ═══════════════════════════════════════════════════════════════════
# SMART CACHE SYSTEM — Popularity-based routing (Algoritma Pengunjung)
# ─────────────────────────────────────────────────────────────────
# - Traffic rendah (< HOT_THRESHOLD req/menit per slug):
#     → Fetch fresh dari server sumber
# - Traffic tinggi (>= HOT_THRESHOLD req/menit per slug):
#     → Serve langsung dari DB cache (mencegah spam hit ke target)
# ═══════════════════════════════════════════════════════════════════
from collections import defaultdict

HOT_THRESHOLD   = 5    # req/menit per key -> cache
WINDOW_SECONDS  = 60

_req_window: dict = defaultdict(list)
_req_lock = threading.Lock()

def _count_request(key: str) -> int:
    now = time.time()
    with _req_lock:
        window = [t for t in _req_window[key] if now - t < WINDOW_SECONDS]
        window.append(now)
        _req_window[key] = window
        return len(window)

_inflight_events: dict = {}
_inflight_results: dict = {}
_inflight_lock = threading.Lock()

def _fetch_once(key: str, fetch_fn):
    with _inflight_lock:
        if key in _inflight_events:
            ev = _inflight_events[key]
            is_leader = False
        else:
            ev = threading.Event()
            _inflight_events[key] = ev
            _inflight_results[key] = None
            is_leader = True

    if not is_leader:
        ev.wait(timeout=20)
        return _inflight_results.get(key)

    try:
        result = fetch_fn()
        _inflight_results[key] = result
        return result
    except Exception as e:
        _inflight_results[key] = None
        return None
    finally:
        ev.set()
        def _cleanup():
            time.sleep(5)
            with _inflight_lock:
                _inflight_events.pop(key, None)
                _inflight_results.pop(key, None)
        threading.Thread(target=_cleanup, daemon=True).start()

# ----------------- CACHE MANAGER -----------------
class CacheManager:
    def __init__(self, db_path=DB_PATH):
        self.db_path = db_path
        self.locks = {}
        self.locks_lock = threading.Lock()
        self._init_db()

    def _get_connection(self):
        return get_db_connection(self.db_path)

    def _init_db(self):
        with DB_WRITE_LOCK:
            conn = self._get_connection()
            c = conn.cursor()
            c.execute('''
                CREATE TABLE IF NOT EXISTS cache (
                    key TEXT PRIMARY KEY,
                    data TEXT,
                    updated_at REAL,
                    expires_at REAL
                )
            ''')
            c.execute('''
                CREATE TABLE IF NOT EXISTS anime_details (
                    slug TEXT PRIMARY KEY,
                    data TEXT NOT NULL,
                    status TEXT,
                    updated_at REAL NOT NULL
                )
            ''')
            c.execute('''
                CREATE TABLE IF NOT EXISTS episode_details (
                    slug TEXT PRIMARY KEY,
                    data TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
            ''')
            c.execute('''
                CREATE TABLE IF NOT EXISTS anime_image_cache (
                    image_url TEXT PRIMARY KEY,
                    file_id TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
            ''')
            c.execute('''
                CREATE TABLE IF NOT EXISTS cover_slug_mapping (
                    slug TEXT PRIMARY KEY,
                    image_url TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
            ''')
            conn.commit()
            conn.close()

    def get_lock(self, key):
        with self.locks_lock:
            if key not in self.locks:
                self.locks[key] = threading.Lock()
            return self.locks[key]

    def get(self, key):
        try:
            conn = self._get_connection()
            c = conn.cursor()
            c.execute('SELECT data, updated_at, expires_at FROM cache WHERE key = ?', (key,))
            row = c.fetchone()
            conn.close()
            if row:
                return {
                    'data': json.loads(row[0]),
                    'updated_at': row[1],
                    'expires_at': row[2]
                }
        except Exception as e:
            print(f"Cache get error: {e}")
        return None

    def set(self, key, data, ttl_seconds):
        try:
            now = time.time()
            expires_at = now + ttl_seconds
            with DB_WRITE_LOCK:
                conn = self._get_connection()
                c = conn.cursor()
                c.execute('''
                    INSERT OR REPLACE INTO cache (key, data, updated_at, expires_at)
                    VALUES (?, ?, ?, ?)
                ''', (key, json.dumps(data), now, expires_at))
                conn.commit()
                conn.close()
        except Exception as e:
            print(f"Cache set error: {e}")

    def delete(self, key):
        try:
            with DB_WRITE_LOCK:
                conn = self._get_connection()
                c = conn.cursor()
                c.execute('DELETE FROM cache WHERE key = ?', (key,))
                conn.commit()
                conn.close()
            print(f"Evicted cache key: {key}")
        except Exception as e:
            print(f"Cache delete error: {e}")

    def get_anime_detail(self, slug):
        try:
            conn = self._get_connection()
            c = conn.cursor()
            c.execute('SELECT data, status, updated_at FROM anime_details WHERE slug = ?', (slug,))
            row = c.fetchone()
            conn.close()
            if row:
                return {
                    'data': json.loads(row[0]),
                    'status': row[1],
                    'updated_at': row[2]
                }
        except Exception as e:
            print(f"Error getting anime detail: {e}")
        return None

    def set_anime_detail(self, slug, data):
        try:
            with DB_WRITE_LOCK:
                conn = self._get_connection()
                c = conn.cursor()
                c.execute('''
                    INSERT OR REPLACE INTO anime_details (slug, data, status, updated_at)
                    VALUES (?, ?, ?, ?)
                ''', (slug, json.dumps(data), data.get('status', ''), time.time()))
                conn.commit()
                conn.close()
        except Exception as e:
            print(f"Error setting anime detail: {e}")

    def get_episode_detail(self, slug):
        try:
            conn = self._get_connection()
            c = conn.cursor()
            c.execute('SELECT data, updated_at FROM episode_details WHERE slug = ?', (slug,))
            row = c.fetchone()
            conn.close()
            if row:
                return {
                    'data': json.loads(row[0]),
                    'updated_at': row[1]
                }
        except Exception as e:
            print(f"Error getting episode detail: {e}")
        return None

    def set_episode_detail(self, slug, data):
        try:
            with DB_WRITE_LOCK:
                conn = self._get_connection()
                c = conn.cursor()
                c.execute('''
                    INSERT OR REPLACE INTO episode_details (slug, data, updated_at)
                    VALUES (?, ?, ?)
                ''', (slug, json.dumps(data), time.time()))
                conn.commit()
                conn.close()
        except Exception as e:
            print(f"Error setting episode detail: {e}")

    def delete_episode_detail(self, slug):
        try:
            with DB_WRITE_LOCK:
                conn = self._get_connection()
                c = conn.cursor()
                c.execute('DELETE FROM episode_details WHERE slug = ?', (slug,))
                conn.commit()
                conn.close()
            print(f"Deleted episode detail DB cache: {slug}")
        except Exception as e:
            print(f"Error deleting episode detail: {e}")

    def fuzzy_search(self, query):
        results = []
        try:
            import re
            def calc_similarity(s1, s2):
                clean_s1 = re.sub(r'[^a-zA-Z0-9]', '', s1).lower()
                clean_s2 = re.sub(r'[^a-zA-Z0-9]', '', s2).lower()
                if not clean_s1 or not clean_s2:
                    return 0.0
                if clean_s1 in clean_s2 or clean_s2 in clean_s1:
                    return 1.0
                m, n = len(clean_s1), len(clean_s2)
                dp = [[0] * (n + 1) for _ in range(m + 1)]
                for i in range(m + 1):
                    dp[i][0] = i
                for j in range(n + 1):
                    dp[0][j] = j
                for i in range(1, m + 1):
                    for j in range(1, n + 1):
                        if clean_s1[i - 1] == clean_s2[j - 1]:
                            dp[i][j] = dp[i - 1][j - 1]
                        else:
                            dp[i][j] = min(
                                dp[i - 1][j] + 1,
                                dp[i][j - 1] + 1,
                                dp[i - 1][j - 1] + 1
                            )
                distance = dp[m][n]
                max_len = max(m, n)
                return (max_len - distance) / max_len

            conn = self._get_connection()
            c = conn.cursor()
            c.execute("SELECT data FROM anime_details")
            rows = c.fetchall()
            c.execute("SELECT data FROM cache WHERE key LIKE 'detail_%'")
            rows += c.fetchall()
            conn.close()
            
            seen_slugs = set()
            scored_results = []
            for row in rows:
                anime = json.loads(row[0])
                title = anime.get('title', '')
                japanese = anime.get('japanese', '')
                slug = anime.get('slug', '')
                
                if slug in seen_slugs:
                    continue
                    
                score_title = calc_similarity(query, title)
                score_jap = calc_similarity(query, japanese)
                best_score = max(score_title, score_jap)
                
                # Match if similarity is >= 0.62 (allows minor typos and space differences)
                if best_score >= 0.62:
                    seen_slugs.add(slug)
                    scored_results.append((best_score, {
                        'title': title,
                        'slug': slug,
                        'thumb': anime.get('thumb', ''),
                        'status': anime.get('status', 'Cached'),
                        'rating': anime.get('rating', 'N/A'),
                        'genres': anime.get('genres', [])
                    }))
            
            # Sort results by similarity score descending
            scored_results.sort(key=lambda x: x[0], reverse=True)
            results = [item[1] for item in scored_results]
        except Exception as e:
            print(f"Fuzzy search error: {e}")
        return results

    def get_data_swr(self, key, fetch_fn, ttl_seconds):
        req_count = _count_request(key)
        cache_entry = self.get(key)
        now = time.time()

        if not cache_entry:
            # Cache miss: fetch synchronously with stampede prevention
            print(f"[SMART CACHE] Miss for '{key}'. Fetching fresh...")
            fresh_data = _fetch_once(key, fetch_fn)
            if fresh_data:
                self.set(key, fresh_data, ttl_seconds)
                return fresh_data, "MISS"
            else:
                raise Exception("Scraping returned empty or failed.")

        is_stale = now >= cache_entry['expires_at']

        if not is_stale:
            # Cache is still fresh, serve immediately
            return cache_entry['data'], "HIT"

        # Cache is stale. Decide how to refresh based on traffic.
        if req_count < HOT_THRESHOLD:
            # Low Traffic: fetch fresh synchronously
            print(f"[SMART CACHE] Low traffic ({req_count} req/m) for '{key}'. Synchronous refresh...")
            fresh_data = _fetch_once(key, fetch_fn)
            if fresh_data:
                self.set(key, fresh_data, ttl_seconds)
                return fresh_data, "HIT_REFRESHED"
            else:
                return cache_entry['data'], "HIT_STALE_FALLBACK"
        else:
            # High Traffic: serve stale immediately, refresh in background
            key_lock = self.get_lock(key)
            if key_lock.acquire(blocking=False):
                def refresh_task():
                    try:
                        print(f"[SMART CACHE] Background refresh for '{key}'...")
                        fresh = _fetch_once(key, fetch_fn)
                        if fresh:
                            self.set(key, fresh, ttl_seconds)
                    except Exception as e:
                        print(f"[SMART CACHE] Error refreshing '{key}': {e}")
                    finally:
                        key_lock.release()
                
                threading.Thread(target=refresh_task, daemon=True).start()
            return cache_entry['data'], "HIT_STALE_BACKGROUND"

cache_manager = CacheManager()

# ----------------- PARSERS & UTILS -----------------
def get_slug(url):
    parts = [p for p in url.strip('/').split('/') if p]
    if parts:
        return parts[-1]
    return ''

def fetch_html(url, referer=None):
    r = requests.get(url, headers=get_headers(referer), timeout=10)
    if r.status_code != 200:
        raise Exception(f"Failed to fetch {url}, status code {r.status_code}")
    return r.text

def parse_home_html(html):
    soup = BeautifulSoup(html, 'html.parser')
    venz_elements = soup.select('.venz')
    
    ongoing = []
    completed = []
    
    # Process Ongoing (Venz 0)
    if len(venz_elements) > 0:
        for post in venz_elements[0].select('.detpost'):
            title_el = post.select_one('.jdlflm')
            ep_el = post.select_one('.epz')
            day_el = post.select_one('.epztipe')
            date_el = post.select_one('.newnime')
            thumb_el = post.select_one('.thumbz img')
            a_el = post.select_one('.thumb a')
            
            if a_el and title_el:
                url = a_el['href']
                ongoing.append({
                    'title': title_el.text.strip(),
                    'slug': get_slug(url),
                    'url': url,
                    'episode': ep_el.text.strip() if ep_el else '',
                    'day': day_el.text.strip() if day_el else '',
                    'date': date_el.text.strip() if date_el else '',
                    'thumb': thumb_el['src'] if thumb_el else ''
                })
                
    # Process Completed (Venz 1)
    if len(venz_elements) > 1:
        for post in venz_elements[1].select('.detpost'):
            title_el = post.select_one('.jdlflm')
            ep_el = post.select_one('.epz')
            day_el = post.select_one('.epztipe')
            date_el = post.select_one('.newnime')
            thumb_el = post.select_one('.thumbz img')
            a_el = post.select_one('.thumb a')
            
            if a_el and title_el:
                url = a_el['href']
                completed.append({
                    'title': title_el.text.strip(),
                    'slug': get_slug(url),
                    'url': url,
                    'episode': ep_el.text.strip() if ep_el else '',
                    'day': day_el.text.strip() if day_el else '',
                    'date': date_el.text.strip() if date_el else '',
                    'thumb': thumb_el['src'] if thumb_el else ''
                })
                
    return {'ongoing': ongoing, 'completed': completed}

def parse_detail_html(html, slug):
    soup = BeautifulSoup(html, 'html.parser')
    
    info = {
        'title': '',
        'japanese': '',
        'rating': 'N/A',
        'producer': '',
        'type': '',
        'status': '',
        'episodes_count': '',
        'duration': '',
        'release_date': '',
        'studio': '',
        'genres': [],
        'thumb': '',
        'synopsis': '',
        'episodes': [],
        'slug': slug
    }
    
    # Title from breadcrumb or h1
    h1 = soup.select_one('.jjudul') or soup.select_one('.postent h1')
    if h1:
        info['title'] = h1.text.strip().replace(' Subtitle Indonesia', '')
    
    # Thumbnail
    thumb_img = soup.select_one('.fotoanime img')
    if thumb_img:
        info['thumb'] = thumb_img['src']
        
    # Details in .infozingle
    for p in soup.select('.infozingle p'):
        span = p.find('span')
        if span:
            b = span.find('b')
            if b:
                key = b.text.strip().replace(':', '').lower()
                val = span.text.replace(b.text, '').strip().strip(':').strip()
                
                if 'judul' in key:
                    info['title'] = val
                elif 'japanese' in key:
                    info['japanese'] = val
                elif 'skor' in key or 'rating' in key:
                    info['rating'] = val
                elif 'produser' in key:
                    info['producer'] = val
                elif 'tipe' in key:
                    info['type'] = val
                elif 'status' in key:
                    info['status'] = val
                elif 'episode' in key:
                    info['episodes_count'] = val
                elif 'durasi' in key:
                    info['duration'] = val
                elif 'rilis' in key:
                    info['release_date'] = val
                elif 'studio' in key:
                    info['studio'] = val
                elif 'genre' in key:
                    info['genres'] = [g.text.strip() for g in span.find_all('a')]
                    
    # Synopsis
    sinop = soup.select_one('.sinopc')
    if sinop:
        info['synopsis'] = sinop.text.strip()
        
    # Episode Lists (Find the episodelist with links containing /episode/)
    eps_lists = soup.select('.episodelist')
    for el in eps_lists:
        li_items = el.select('li')
        for li in li_items:
            a = li.select_one('a')
            if a and '/episode/' in a.get('href', ''):
                ep_url = a['href']
                date_span = li.select_one('.zeebr')
                info['episodes'].append({
                    'title': a.text.strip(),
                    'slug': get_slug(ep_url),
                    'date': date_span.text.strip() if date_span else '',
                    'url': ep_url
                })
                
    return info

def parse_episode_html(html, slug):
    soup = BeautifulSoup(html, 'html.parser')
    
    # Find navigation
    prev_slug = ''
    next_slug = ''
    anime_slug = ''
    
    flir = soup.select_one('.flir')
    if flir:
        links = flir.select('a')
        for l in links:
            txt = l.text.strip().lower()
            href = l.get('href', '')
            link_slug = get_slug(href)
            if 'prev' in txt:
                prev_slug = link_slug
            elif 'next' in txt:
                next_slug = link_slug
            elif 'all' in txt or 'see' in txt:
                anime_slug = link_slug

    # Default embed player iframe src
    default_stream = ''
    pembed = soup.select_one('#pembed iframe')
    if pembed:
        default_stream = pembed.get('src')
        
    # Mirror Stream lists
    mirrors = []
    mirrorstream = soup.select_one('.mirrorstream')
    if mirrorstream:
        # Each ul represents a quality tier
        for ul in mirrorstream.select('ul'):
            res_class = ul.get('class', [''])
            res_text = ul.find('span')
            # Extract resolution from class name or text (e.g. m360p -> 360p)
            resolution = "360p"
            for c in res_class:
                if c.startswith('m') and c[1:-1].isdigit():
                    resolution = c[1:]
                    break
            if res_text and 'Mirror' in res_text.text:
                resolution = res_text.text.replace('Mirror', '').strip()
                
            # Grab all server options inside this resolution list
            for a in ul.select('li a'):
                content = a.get('data-content')
                server_name = a.text.strip()
                if content:
                    mirrors.append({
                        'name': server_name,
                        'content': content,
                        'resolution': resolution
                    })
                    
    # Scrape wordpress action hashes for script decryption
    action_nonce = 'aa1208d27f29ca340c92c66d1926f13f'
    action_stream = '2a3505c93b0035d3f455df82bf976b84'
    
    # Try parsing action hashes dynamically from inline scripts
    script_text = ""
    for script in soup.find_all('script'):
        code = script.string or ""
        if 'mirrorstream' in code and 'admin-ajax' in code:
            script_text = code
            break
            
    if script_text:
        nonce_match = re.search(r'\{\s*action\s*:\s*["\']([a-f0-9]{32})["\']\s*\}', script_text)
        stream_match = re.search(r'nonce\s*:\s*[^,]+,\s*action\s*:\s*["\']([a-f0-9]{32})["\']', script_text)
        if nonce_match:
            action_nonce = nonce_match.group(1)
        if stream_match:
            action_stream = stream_match.group(1)
            
    # Title
    title = soup.title.string.replace(' Subtitle Indonesia', '') if soup.title else 'Watch Episode'
    h1 = soup.select_one('.venutama h1')
    if h1:
        title = h1.text.strip()

    return {
        'title': title,
        'slug': slug,
        'default_stream': default_stream,
        'mirrors': mirrors,
        'navigation': {
            'prev': prev_slug,
            'next': next_slug,
            'anime': anime_slug
        },
        'action_nonce': action_nonce,
        'action_stream': action_stream
    }

def parse_search_html(html):
    soup = BeautifulSoup(html, 'html.parser')
    results = []
    
    chivsrc = soup.select_one('.chivsrc')
    if chivsrc:
        for li in chivsrc.select('li'):
            a = li.select_one('h2 a')
            img = li.select_one('img')
            
            # Fetch details status, rating, genres
            status = 'N/A'
            rating = 'N/A'
            genres = []
            
            for div in li.select('.set'):
                txt = div.text.strip()
                if 'Status' in txt:
                    status = txt.replace('Status :', '').strip()
                elif 'Rating' in txt or 'Skor' in txt:
                    rating = txt.replace('Rating :', '').replace('Skor :', '').strip()
                elif 'Genres' in txt:
                    genres = [g.text.strip() for g in div.find_all('a')]
            
            if a:
                url = a['href']
                results.append({
                    'title': a.text.strip().replace(' Subtitle Indonesia', ''),
                    'slug': get_slug(url),
                    'url': url,
                    'thumb': img['src'] if img else '',
                    'status': status,
                    'rating': rating,
                    'genres': genres
                })
    return results

def parse_schedule_html(html):
    soup = BeautifulSoup(html, 'html.parser')
    schedule = {}
    kglist_divs = soup.select('.kglist321')
    for div in kglist_divs:
        h2 = div.select_one('h2')
        ul = div.select_one('ul')
        if h2 and ul:
            day = h2.text.strip()
            schedule[day] = []
            for li in ul.select('li'):
                a = li.select_one('a')
                if a:
                    schedule[day].append({
                        'title': a.text.strip(),
                        'slug': get_slug(a['href'])
                    })
    return schedule

def parse_genres_html(html):
    soup = BeautifulSoup(html, 'html.parser')
    genres = []
    genres_ul = soup.select_one('ul.genres')
    if genres_ul:
        for a in genres_ul.select('a'):
            href = a.get('href', '')
            genres.append({
                'name': a.text.strip(),
                'slug': get_slug(href)
            })
            
    # Inject missing hidden genres that exist on Otakudesu but are omitted from their index
    hidden_genres = [
        {'name': 'Isekai', 'slug': 'isekai'},
        {'name': 'Donghua', 'slug': 'donghua'},
        {'name': 'Live Action', 'slug': 'live-action'},
        {'name': 'Gore', 'slug': 'gore'},
        {'name': 'Suspense', 'slug': 'suspense'},
        {'name': 'Reincarnation', 'slug': 'reincarnation'},
        {'name': 'Mahou Shoujo', 'slug': 'mahou-shoujo'},
        {'name': 'Kids', 'slug': 'kids'}
    ]
    
    existing_slugs = {g['slug'] for g in genres}
    for hg in hidden_genres:
        if hg['slug'] not in existing_slugs:
            genres.append(hg)
            
    # Sort genres alphabetically by name
    genres.sort(key=lambda x: x['name'].lower())
    
    return genres

def parse_genre_detail_html(html):
    soup = BeautifulSoup(html, 'html.parser')
    anime_list = []
    for post in soup.select('.col-anime'):
        title_el = post.select_one('.col-anime-title a')
        rating_el = post.select_one('.col-anime-rating')
        eps_el = post.select_one('.col-anime-eps')
        thumb_el = post.select_one('.col-anime-cover img')
        studio_el = post.select_one('.col-anime-studio')
        
        if title_el:
            anime_list.append({
                'title': title_el.text.strip(),
                'slug': get_slug(title_el['href']),
                'rating': rating_el.text.strip() if rating_el else '',
                'episode': eps_el.text.strip() if eps_el else '',
                'thumb': thumb_el['src'] if thumb_el else '',
                'studio': studio_el.text.strip() if studio_el else ''
            })
    return anime_list

def parse_anime_list_html(html):
    soup = BeautifulSoup(html, 'html.parser')
    anime_list = []
    daftaranime_container = soup.select_one('.daftaranime')
    if daftaranime_container:
        for a in daftaranime_container.select('a'):
            href = a.get('href', '')
            if '/anime/' in href:
                title = a.text.strip()
                if title:
                    anime_list.append({
                        'title': title,
                        'slug': get_slug(href)
                    })
    else:
        for a in soup.select('a'):
            href = a.get('href', '')
            if '/anime/' in href and a.text.strip():
                anime_list.append({
                    'title': a.text.strip(),
                    'slug': get_slug(href)
                })
    return anime_list

# ----------------- TELEGRAM BOT INTEGRATION -----------------
# Thread Pool for background uploads
executor = concurrent.futures.ThreadPoolExecutor(max_workers=50)

def enrich_anime_items(items):
    if not items:
        return items
        
    conn = get_db_connection()
    c = conn.cursor()
    
    slugs_to_fetch = []
    for item in items:
        slug = item.get('slug')
        if not slug:
            continue
            
        ep = str(item.get('episode') or '').strip().lower()
        is_unknown = not ep or ep == '?' or 'unknown' in ep or ep.startswith('?') or ep == '? eps'
        
        if is_unknown:
            c.execute('SELECT data FROM anime_details WHERE slug = ?', (slug,))
            row = c.fetchone()
            if row:
                try:
                    db_detail = json.loads(row[0])
                    db_eps = db_detail.get('episodes_count') or ''
                    if not db_eps or db_eps == '?' or 'unknown' in db_eps.lower() or db_eps.startswith('?'):
                        if db_detail.get('episodes'):
                            db_eps = f"{len(db_detail['episodes'])} Eps"
                    
                    if db_eps and db_eps != '?' and 'unknown' not in db_eps.lower() and not db_eps.startswith('?'):
                        if not db_eps.lower().endswith('eps') and not db_eps.lower().endswith('episode') and not db_eps.lower().endswith('episodes'):
                            db_eps = f"{db_eps} Eps"
                        item['episode'] = db_eps
                        is_unknown = False
                except Exception:
                    pass
                    
        if is_unknown:
            slugs_to_fetch.append(slug)
            
    conn.close()
    
    if slugs_to_fetch:
        def scrape_and_cache(slug):
            try:
                url = urllib.parse.urljoin(BASE_URL, f"anime/{slug}/")
                html = fetch_html(url)
                data = parse_detail_html(html, slug)
                if data:
                    cache_manager.set_anime_detail(slug, data)
                    if data.get('thumb'):
                        trigger_single_image_upload(data['thumb'], slug)
                    return slug, data
            except Exception as e:
                print(f"Error enriching detail for {slug}: {e}")
            return slug, None
            
        futures = {executor.submit(scrape_and_cache, slug): slug for slug in slugs_to_fetch[:8]}
        done, not_done = concurrent.futures.wait(futures.keys(), timeout=2.0)
        
        success_details = {}
        for f in done:
            slug, data = f.result()
            if data:
                success_details[slug] = data
                
        for item in items:
            slug = item.get('slug')
            if slug in success_details:
                data = success_details[slug]
                db_eps = data.get('episodes_count') or ''
                if not db_eps or db_eps == '?' or 'unknown' in db_eps.lower() or db_eps.startswith('?'):
                    if data.get('episodes'):
                        db_eps = f"{len(data['episodes'])} Eps"
                if db_eps and db_eps != '?' and 'unknown' not in db_eps.lower() and not db_eps.startswith('?'):
                    if not db_eps.lower().endswith('eps') and not db_eps.lower().endswith('episode') and not db_eps.lower().endswith('episodes'):
                        db_eps = f"{db_eps} Eps"
                    item['episode'] = db_eps
                    
    return items

def encode_url_to_filename(url, ext):
    encoded = base64.urlsafe_b64encode(url.encode('utf-8')).decode('utf-8')
    return f"cover_{encoded}.{ext}"

def decode_filename_to_url(filename):
    if not filename.startswith("cover_"):
        return None
    try:
        parts = filename.split('.', 1)
        name_part = parts[0][6:]  # skip "cover_"
        decoded_bytes = base64.urlsafe_b64decode(name_part.encode('utf-8'))
        return decoded_bytes.decode('utf-8')
    except Exception:
        return None

def load_bot_tokens():
    tokens = []
    # 1. Try from environment variable BOT_TOKEN or BOT_TOKENS
    for key in ["BOT_TOKEN", "BOT_TOKENS"]:
        env_tokens = os.environ.get(key)
        if env_tokens:
            tokens = [t.strip() for t in env_tokens.split(',') if t.strip()]
            break
            
    # 2. Try reading from root .env
    if not tokens:
        env_path = os.path.join(BASE_DIR, ".env")
        if os.path.exists(env_path):
            try:
                with open(env_path, "r") as f:
                    for line in f:
                        if line.startswith("BOT_TOKENS=") or line.startswith("BOT_TOKEN="):
                            tokens_str = line.strip().split("=", 1)[1].strip('"').strip("'")
                            tokens = [t.strip() for t in tokens_str.split(',') if t.strip()]
                            break
            except Exception:
                pass
    return tokens

def load_chat_ids():
    """Load chat IDs with .last_chat_id always taking highest priority.
    This ensures the most recent/active chat (user or group) is always tried first.
    """
    base_paths = [
        os.path.join(BASE_DIR, "Tautatkan ke Bot Tele Termux"),
        os.path.join(BASE_DIR, "Bot_Tele_Termux"),
        BASE_DIR,
        os.path.join(BASE_DIR, "backend")
    ]

    last_chat_id = None
    static_chat_ids = []

    # Step 1: Always read .last_chat_id first (most dynamic — can be user or group)
    for bp in base_paths:
        last_chat_path = os.path.join(bp, ".last_chat_id")
        if os.path.exists(last_chat_path):
            try:
                with open(last_chat_path, "r") as f:
                    cid = f.read().strip()
                    if cid:
                        last_chat_id = cid
                        break
            except Exception:
                pass

    # Step 2: Read .chat_ids as a supplemental pool
    for bp in base_paths:
        chat_ids_path = os.path.join(bp, ".chat_ids")
        if os.path.exists(chat_ids_path):
            try:
                with open(chat_ids_path, "r") as f:
                    lines = [line.strip() for line in f if line.strip()]
                    if lines:
                        static_chat_ids = lines
                        break
            except Exception:
                pass

    # Merge: last_chat_id first, then static list (deduped, preserve order)
    seen = set()
    result = []
    for cid in ([last_chat_id] if last_chat_id else []) + static_chat_ids:
        if cid and cid not in seen:
            seen.add(cid)
            result.append(cid)

    return result

def get_valid_route(tokens, chat_ids):
    if not tokens or not chat_ids:
        return None, None, None
    token = random.choice(tokens)
    chat_id = random.choice(chat_ids)
    return tokens.index(token), token, chat_id

def background_upload_single_image(url, chat_ids, slug=None):
    tokens = load_bot_tokens()
    if not tokens or not chat_ids:
        print("[Telegram Upload] No tokens or chat IDs found.")
        return
        
    try:
        # Check if already cached (double check)
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT file_id FROM anime_image_cache WHERE image_url=?", (url,))
        row = cursor.fetchone()
        conn.close()
        if row:
            print(f"[Telegram Upload] Already cached: {url}")
            # If the file exists in cache, delete it
            temp_dir = os.path.join(BASE_DIR, "backend", "cache")
            ext = url.split('.')[-1].split('?')[0]
            if len(ext) > 4 or not ext:
                ext = 'jpg'
            temp_filename = encode_url_to_filename(url, ext)
            cover_path = os.path.join(temp_dir, temp_filename)
            if os.path.exists(cover_path):
                os.remove(cover_path)
            return
            
        # Download cover locally to a temp path
        temp_dir = os.path.join(BASE_DIR, "backend", "cache")
        os.makedirs(temp_dir, exist_ok=True)
        
        ext = url.split('.')[-1].split('?')[0]
        if len(ext) > 4 or not ext:
            ext = 'jpg'
            
        temp_filename = encode_url_to_filename(url, ext)
        cover_path = os.path.join(temp_dir, temp_filename)
        
        if not os.path.exists(cover_path):
            try:
                r = requests.get(url, headers={'User-Agent': 'Mozilla/5.0', 'Referer': BASE_URL}, timeout=15)
                if r.status_code != 200:
                    print(f"[Telegram Upload] Failed download cover: {url}, status code {r.status_code}")
                    return
                with open(cover_path, "wb") as f:
                    f.write(r.content)
            except Exception as e:
                print(f"[Telegram Upload] Failed to save cover locally: {e}")
                if os.path.exists(cover_path):
                    os.remove(cover_path)
                return

        # Upload to Telegram
        success = False
        for attempt in range(5):
            token_idx, token, chat_id = get_valid_route(tokens, chat_ids)
            if not token:
                break
                
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
                    
                    # Delete the message
                    msg_id = resp["result"]["message_id"]
                    try:
                        del_url = f"https://api.telegram.org/bot{token}/deleteMessage"
                        requests.post(del_url, data={"chat_id": chat_id, "message_id": msg_id}, timeout=5)
                    except Exception:
                        pass
                        
                    # Save to db
                    with DB_WRITE_LOCK:
                        conn = get_db_connection()
                        cursor = conn.cursor()
                        cursor.execute("INSERT OR REPLACE INTO anime_image_cache (image_url, file_id, updated_at) VALUES (?, ?, ?)", (url, file_id, time.time()))
                        conn.commit()
                        conn.close()
                    print(f"[Telegram Upload] Successfully cached: {url} -> {file_id}")
                    success = True
                    break
                else:
                    print(f"[Telegram Upload] Attempt {attempt+1} failed: {resp.get('description')}")
                    time.sleep(1)
            except Exception as e:
                print(f"[Telegram Upload] Attempt {attempt+1} exception: {e}")
                time.sleep(1)
                
        # Clean up local file
        if os.path.exists(cover_path):
            try:
                os.remove(cover_path)
            except Exception:
                pass
                
    except Exception as e:
        print(f"[Telegram Upload] Task failed: {e}")

def trigger_single_image_upload(url, slug=None):
    if os.environ.get('SKIP_TELEGRAM') == 'true':
        return
    try:
        chat_ids = load_chat_ids()
        if chat_ids:
            executor.submit(background_upload_single_image, url, chat_ids, slug)
    except Exception as e:
        print(f"[Telegram Upload] Trigger failed: {e}")

def resume_pending_uploads():
    if os.environ.get('SKIP_TELEGRAM') == 'true':
        return
    print("[Telegram Startup] Scanning for pending cover uploads in cache...")
    temp_dir = os.path.join(BASE_DIR, "backend", "cache")
    if not os.path.exists(temp_dir):
        return
        
    try:
        files = os.listdir(temp_dir)
        count = 0
        for f in files:
            if f.startswith("cover_"):
                url = decode_filename_to_url(f)
                if url:
                    print(f"[Telegram Startup] Resuming upload for cached file: {f} -> {url}")
                    trigger_single_image_upload(url)
                    count += 1
                else:
                    # Clean up old timestamp-based or unparseable files to keep folder clean
                    try:
                        os.remove(os.path.join(temp_dir, f))
                    except Exception:
                        pass
        if count > 0:
            print(f"[Telegram Startup] Resumed {count} pending uploads from cache folder.")
    except Exception as e:
        print(f"[Telegram Startup] Error resuming pending uploads: {e}")

def upload_all_missing_covers():
    if os.environ.get('SKIP_TELEGRAM') == 'true':
        return
    print("[Telegram Startup] Scanning database for any missing cover uploads...")
    try:
        conn = get_db_connection()
        c = conn.cursor()
        c.execute("SELECT data FROM anime_details")
        rows = c.fetchall()
        
        c.execute("SELECT image_url FROM anime_image_cache")
        cached_urls = set(row[0] for row in c.fetchall())
        conn.close()
        
        triggered_count = 0
        for row in rows:
            try:
                anime_data = json.loads(row[0])
                thumb = anime_data.get('thumb')
                slug = anime_data.get('slug')
                if thumb and thumb.startswith("http") and thumb not in cached_urls:
                    trigger_single_image_upload(thumb, slug)
                    triggered_count += 1
            except Exception:
                pass
        if triggered_count > 0:
            print(f"[Telegram Startup] Triggered parallel background uploads for {triggered_count} missing covers.")
    except Exception as e:
        print(f"[Telegram Startup] Error scanning database for missing covers: {e}")

def translate_thumbnail(url, slug):
    if not url or not slug:
        return url
    try:
        with DB_WRITE_LOCK:
            conn = get_db_connection()
            c = conn.cursor()
            c.execute('INSERT OR REPLACE INTO cover_slug_mapping (slug, image_url, updated_at) VALUES (?, ?, ?)', (slug, url, time.time()))
            conn.commit()
            conn.close()
    except Exception as e:
        print(f"[Database] Failed to write cover mapping for {slug}: {e}")
    return f"/api/image/cover-{slug}.jpg"

def translate_covers_in_obj(obj):
    """Walks the JSON object and translates all 'thumb' or 'cover' URLs to local/Telegram proxy URLs."""
    if isinstance(obj, dict):
        new_dict = {}
        slug = obj.get("slug")
            
        for k, v in obj.items():
            if (k == "thumb" or k == "cover") and isinstance(v, str) and v.startswith("http"):
                item_slug = slug or get_slug(obj.get("url", "")) or get_slug(v)
                new_dict[k] = translate_thumbnail(v, item_slug)
            else:
                new_dict[k] = translate_covers_in_obj(v)
        return new_dict
    elif isinstance(obj, list):
        return [translate_covers_in_obj(item) for item in obj]
    else:
        return obj

def resolve_shadow_file_id(shadow_id):
    if not shadow_id:
        return ""
        
    is_cover = False
    slug = ""
    if shadow_id.startswith('cover:'):
        is_cover = True
        slug = shadow_id.replace('cover:', '')
        
    if is_cover:
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT data FROM anime_details WHERE slug=?", (slug,))
            row = cursor.fetchone()
            if row:
                anime_data = json.loads(row[0])
                cover_url = anime_data.get('thumb')
                if cover_url:
                    cursor.execute("SELECT file_id FROM anime_image_cache WHERE image_url=?", (cover_url,))
                    row2 = cursor.fetchone()
                    if row2:
                        conn.close()
                        return row2[0]
            conn.close()
        except Exception as e:
            print(f"Error resolving shadow cover id: {e}")
            
    return shadow_id

def stream_original_image(original_url):
    try:
        ref_url = "https://otakudesu.cloud/"
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': ref_url
        }
        r = requests.get(original_url, headers=headers, timeout=10)
        if r.status_code == 200:
            content_type = r.headers.get('Content-Type', 'image/jpeg')
            return send_file(io.BytesIO(r.content), mimetype=content_type)
    except Exception as e:
        print(f"Error streaming fallback image: {e}")
    return redirect(original_url)

@app.route('/api/image/cover-<slug>.jpg')
@app.route('/api/image/cover-<slug>')
def api_image_cover_alias(slug):
    """Serve cover image using secure alias instead of raw Telegram file_id"""
    try:
        # 1. Look up original_url from cover_slug_mapping
        original_url = None
        conn = get_db_connection()
        c = conn.cursor()
        c.execute('SELECT image_url FROM cover_slug_mapping WHERE slug = ?', (slug,))
        row = c.fetchone()
        conn.close()
        
        if row:
            original_url = row[0]
        else:
            # Fallback: search in anime_details
            try:
                conn = get_db_connection()
                c = conn.cursor()
                c.execute('SELECT data FROM anime_details WHERE slug = ?', (slug,))
                detail_row = c.fetchone()
                conn.close()
                if detail_row:
                    anime_data = json.loads(detail_row[0])
                    original_url = anime_data.get('thumb')
            except Exception:
                pass
                
        if not original_url:
            return "Cover image mapping not found", 404
            
        if os.environ.get('SKIP_TELEGRAM') == 'true':
            return stream_original_image(original_url)
            
        # 2. Check if we already have the uploaded Telegram file_id for this original_url
        file_id = None
        try:
            conn = get_db_connection()
            c = conn.cursor()
            c.execute('SELECT file_id FROM anime_image_cache WHERE image_url = ?', (original_url,))
            cache_row = c.fetchone()
            conn.close()
            if cache_row:
                file_id = cache_row[0]
        except Exception:
            pass
            
        if file_id:
            # Serve directly from Telegram securely
            tokens = load_bot_tokens()
            if not tokens:
                return stream_original_image(original_url) # Fallback to original url
                
            clean_file_id = file_id
            resolved_id = resolve_shadow_file_id(clean_file_id)
            
            token = tokens[0]
            tried_tokens = [token] + [t for t in tokens if t != token]
            last_error = None
            
            for try_token in tried_tokens:
                file_info_url = f"https://api.telegram.org/bot{try_token}/getFile?file_id={resolved_id}"
                try:
                    info_resp = requests.get(file_info_url, timeout=10).json()
                except Exception as e:
                    last_error = str(e)
                    continue
                    
                if not info_resp.get("ok"):
                    last_error = info_resp.get("description", "Unknown Telegram error")
                    continue
                    
                file_path = info_resp["result"]["file_path"]
                telegram_file_url = f"https://api.telegram.org/file/bot{try_token}/{file_path}"
                
                image_data = None
                content_type = 'image/jpeg'
                for download_attempt in range(3):
                    try:
                        img_req = requests.get(telegram_file_url, timeout=20)
                        if img_req.status_code == 200:
                            image_data = img_req.content
                            content_type = img_req.headers.get('Content-Type', 'image/jpeg')
                            if content_type == 'application/octet-stream':
                                content_type = 'image/jpeg'
                            break
                    except Exception:
                        time.sleep(0.5)
                        
                if image_data:
                    print(f"\033[92m[Telegram]\033[0m Serving cover from Telegram CDN for: cover-{slug}.jpg")
                    return send_file(io.BytesIO(image_data), mimetype=content_type)
                else:
                    last_error = "Failed to download image from Telegram servers"
                    continue
                    
            # Fallback redirect if Telegram load fails
            print(f"\033[93m[Otakudesu Web]\033[0m Serving cover fallback (Telegram Load Failed) for: cover-{slug}.jpg")
            return stream_original_image(original_url)
        else:
            # 3. Trigger background upload & redirect instantly!
            print(f"\033[94m[Otakudesu Web]\033[0m Serving cover fallback (Triggering Upload) for: cover-{slug}.jpg")
            trigger_single_image_upload(original_url, slug=slug)
            return stream_original_image(original_url)
            
    except Exception as e:
        return f"Internal error serving secure cover: {str(e)}", 500

@app.route('/api/image')
def api_image():
    file_id = request.args.get('file_id', '')
    if not file_id:
        return jsonify({"error": "Missing query param: file_id"}), 400
        
    tokens = load_bot_tokens()
    if not tokens:
        return jsonify({"error": "Bot tokens not configured on server."}), 500
        
    clean_file_id = file_id
    resolved_id = resolve_shadow_file_id(clean_file_id)
    
    if resolved_id.startswith('cover:'):
        slug = resolved_id.replace('cover:', '')
        original_url = None
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT data FROM anime_details WHERE slug=?", (slug,))
            row = cursor.fetchone()
            if row:
                anime_data = json.loads(row[0])
                original_url = anime_data.get('thumb')
            conn.close()
        except Exception:
            pass
            
        if original_url:
            trigger_single_image_upload(original_url, slug=slug)
            return redirect(original_url)
        return "Image not found and cannot be resolved", 404
        
    token = tokens[0]
    try:
        tried_tokens = [token] + [t for t in tokens if t != token]
        last_error = None
        
        for try_token in tried_tokens:
            file_info_url = f"https://api.telegram.org/bot{try_token}/getFile?file_id={resolved_id}"
            try:
                info_resp = requests.get(file_info_url, timeout=10).json()
            except Exception as e:
                last_error = str(e)
                continue
                
            if not info_resp.get("ok"):
                last_error = info_resp.get("description", "Unknown Telegram error")
                continue
                
            file_path = info_resp["result"]["file_path"]
            telegram_file_url = f"https://api.telegram.org/file/bot{try_token}/{file_path}"
            
            image_data = None
            content_type = 'image/jpeg'
            for download_attempt in range(3):
                try:
                    img_req = requests.get(telegram_file_url, timeout=20)
                    if img_req.status_code == 200:
                        image_data = img_req.content
                        content_type = img_req.headers.get('Content-Type', 'image/jpeg')
                        if content_type == 'application/octet-stream':
                            content_type = 'image/jpeg'
                        break
                except Exception:
                    time.sleep(0.5)
                    
            if image_data:
                return send_file(io.BytesIO(image_data), mimetype=content_type)
            else:
                last_error = "Failed to download image from Telegram servers"
                continue
                
        return f"Error loading image from Telegram: {last_error}", 500
    except Exception as e:
        return f"Internal error loading image: {str(e)}", 500

def parse_paginated_list(html):
    soup = BeautifulSoup(html, 'html.parser')
    venz = soup.select_one('.venz')
    items = []
    if venz:
        for post in venz.select('.detpost'):
            title_el = post.select_one('.jdlflm')
            ep_el = post.select_one('.epz')
            day_el = post.select_one('.epztipe')
            date_el = post.select_one('.newnime')
            thumb_el = post.select_one('.thumbz img')
            a_el = post.select_one('.thumb a')
            
            if a_el and title_el:
                url = a_el['href']
                items.append({
                    'title': title_el.text.strip(),
                    'slug': get_slug(url),
                    'url': url,
                    'episode': ep_el.text.strip() if ep_el else '',
                    'day': day_el.text.strip() if day_el else '',
                    'date': date_el.text.strip() if date_el else '',
                    'thumb': thumb_el['src'] if thumb_el else ''
                })
    return items

@app.route('/api/ongoing')
def api_ongoing_paginated():
    page = request.args.get('page', 1, type=int)
    try:
        url = f"{BASE_URL}ongoing-anime/" if page == 1 else f"{BASE_URL}ongoing-anime/page/{page}/"
        
        def fetch():
            print(f"[Scraper] Fetching ongoing page {page}...")
            html = fetch_html(url)
            return parse_paginated_list(html)
            
        data, status = cache_manager.get_data_swr(f"ongoing_page_{page}", fetch, ttl_seconds=1800)
        translated_data = translate_covers_in_obj(data)
        
        for item in data:
            if item.get('thumb') and item.get('slug'):
                trigger_single_image_upload(item['thumb'], item['slug'])
                
        return jsonify({'success': True, 'data': translated_data, 'cache_status': status})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/completed')
def api_completed_paginated():
    page = request.args.get('page', 1, type=int)
    try:
        url = f"{BASE_URL}complete-anime/" if page == 1 else f"{BASE_URL}complete-anime/page/{page}/"
        
        def fetch():
            print(f"[Scraper] Fetching completed page {page}...")
            html = fetch_html(url)
            return parse_paginated_list(html)
            
        data, status = cache_manager.get_data_swr(f"completed_page_{page}", fetch, ttl_seconds=3600)
        translated_data = translate_covers_in_obj(data)
        
        for item in data:
            if item.get('thumb') and item.get('slug'):
                trigger_single_image_upload(item['thumb'], item['slug'])
                
        return jsonify({'success': True, 'data': translated_data, 'cache_status': status})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/home-db-genres')
def api_home_db_genres():
    """Fetch anime grouped by popular genres from the local database cache, filtered by status if provided"""
    try:
        status_filter = request.args.get('status', '').strip().lower()
        
        conn = get_db_connection()
        c = conn.cursor()
        c.execute("SELECT data FROM anime_details")
        rows = c.fetchall()
        conn.close()
        
        target_genres = ['Isekai', 'Fantasy', 'Action', 'Comedy', 'Romance']
        genre_data = {g: [] for g in target_genres}
        all_db_counts = {}
        seen_slugs = set()
        
        for row in rows:
            try:
                anime = json.loads(row[0])
                slug = anime.get('slug', '')
                genres = anime.get('genres', [])
                status = anime.get('status', '').strip().lower()
                
                # Apply status filter if present
                if status_filter:
                    if status_filter == 'ongoing' and 'ongoing' not in status:
                        continue
                    if status_filter == 'completed' and 'completed' not in status:
                        continue
                
                # Update total counts for all matching target genres
                for target in target_genres:
                    if any(target.lower() == g.lower().strip() for g in genres):
                        all_db_counts[target] = all_db_counts.get(target, 0) + 1
                
                # Try to place the anime in exactly one carousel, prioritizing its earliest genre
                if slug not in seen_slugs:
                    for g in genres:
                        g_clean = g.strip().lower()
                        target_match = None
                        for target in target_genres:
                            if target.lower() == g_clean:
                                target_match = target
                                break
                        
                        if target_match and len(genre_data[target_match]) < 10:
                            seen_slugs.add(slug)
                            translated_anime = translate_covers_in_obj(anime)
                            raw_ep_count = translated_anime.get('episodes_count', '')
                            if not raw_ep_count or 'unknown' in str(raw_ep_count).lower() or str(raw_ep_count).strip() == '?':
                                eps_list = translated_anime.get('episodes', [])
                                if eps_list:
                                    ep_count = str(len(eps_list))
                                else:
                                    ep_count = '?'
                            else:
                                # Clean up any trailing 'Episode' or 'Eps' in raw count
                                ep_count = str(raw_ep_count).lower().replace('episode', '').replace('eps', '').strip().capitalize()
                                
                            genre_data[target_match].append({
                                'title': translated_anime.get('title'),
                                'slug': translated_anime.get('slug'),
                                'thumb': translated_anime.get('thumb'),
                                'rating': translated_anime.get('rating', 'N/A'),
                                'status': translated_anime.get('status', ''),
                                'type': translated_anime.get('type', ''),
                                'episodes_count': ep_count,
                                'release_date': translated_anime.get('release_date', ''),
                                'studio': translated_anime.get('studio', '')
                            })
                            # Once placed in a carousel, stop checking its other genres
                            break
            except Exception:
                pass
                
        result = []
        for genre in target_genres:
            if genre_data[genre]:
                result.append({
                    'genre': genre,
                    'total': all_db_counts.get(genre, 0),
                    'items': genre_data[genre]
                })
                
        return jsonify({'success': True, 'data': result})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

# ----------------- API GATEWAY ROUTES -----------------

@app.route('/api/home')
def api_home():
    """Fetch homepage ongoing and completed anime with 30 mins SWR cache"""
    try:
        def fetch():
            print("[Scraper] Fetching homepage data...")
            html = fetch_html(BASE_URL)
            return parse_home_html(html)
            
        data, status = cache_manager.get_data_swr("home", fetch, ttl_seconds=1800)
        translated_data = translate_covers_in_obj(data)
        
        # Trigger background upload for all home thumbnails that are not uploaded yet
        for item in (data.get('ongoing', []) + data.get('completed', [])):
            if item.get('thumb') and item.get('slug'):
                trigger_single_image_upload(item['thumb'], item['slug'])
                
        return jsonify({'success': True, 'data': translated_data, 'cache_status': status})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/anime/<slug>')
def api_detail(slug):
    """Fetch anime detail page from local database or Otakudesu scraper"""
    try:
        db_entry = cache_manager.get_anime_detail(slug)
        if db_entry:
            # If status is not Completed and last updated is > 1 hour ago, revalidate in background
            if db_entry['status'] != 'Completed' and (time.time() - db_entry['updated_at'] > 3600):
                def refresh_detail():
                    try:
                        url = urllib.parse.urljoin(BASE_URL, f"anime/{slug}/")
                        html = fetch_html(url)
                        fresh_data = parse_detail_html(html, slug)
                        if fresh_data:
                            cache_manager.set_anime_detail(slug, fresh_data)
                            if fresh_data.get('thumb'):
                                trigger_single_image_upload(fresh_data['thumb'], slug)
                    except Exception as e:
                        print(f"Error background refreshing detail for {slug}: {e}")
                threading.Thread(target=refresh_detail, daemon=True).start()
                
            translated_data = translate_covers_in_obj(db_entry['data'])
            return jsonify({'success': True, 'data': translated_data, 'cache_status': 'DB_HIT'})
            
        # Cache miss, fetch synchronously
        url = urllib.parse.urljoin(BASE_URL, f"anime/{slug}/")
        print(f"[Scraper] Cache miss: Fetching detail data for '{slug}' at {url}...")
        html = fetch_html(url)
        data = parse_detail_html(html, slug)
        if data:
            cache_manager.set_anime_detail(slug, data)
            if data.get('thumb'):
                trigger_single_image_upload(data['thumb'], slug)
            translated_data = translate_covers_in_obj(data)
            return jsonify({'success': True, 'data': translated_data, 'cache_status': 'DB_MISS'})
        else:
            return jsonify({'success': False, 'message': 'Failed to parse detail data'}), 500
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/episode/<slug>')
def api_episode(slug):
    """Fetch episode page details and mirrors from database or Otakudesu scraper"""
    try:
        db_entry = cache_manager.get_episode_detail(slug)
        if db_entry:
            translated_data = translate_covers_in_obj(db_entry['data'])
            return jsonify({'success': True, 'data': translated_data, 'cache_status': 'DB_HIT'})
            
        # Cache miss, fetch synchronously
        url = urllib.parse.urljoin(BASE_URL, f"episode/{slug}/")
        print(f"[Scraper] Cache miss: Fetching episode details for '{slug}' at {url}...")
        html = fetch_html(url)
        data = parse_episode_html(html, slug)
        if data:
            cache_manager.set_episode_detail(slug, data)
            translated_data = translate_covers_in_obj(data)
            return jsonify({'success': True, 'data': translated_data, 'cache_status': 'DB_MISS'})
        else:
            return jsonify({'success': False, 'message': 'Failed to parse episode details'}), 500
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/search')
def api_search():
    """Search anime. Dynamic scraper search, merged with fuzzy local database search"""
    query = request.args.get('q', '').strip()
    if not query:
        return jsonify({'success': False, 'message': 'Missing search query'}), 400
        
    live_results = []
    try:
        # Try dynamic scraper search first
        url = urllib.parse.urljoin(BASE_URL, f"?s={urllib.parse.quote(query)}&post_type=anime")
        print(f"[Search] Fetching search page for '{query}'...")
        html = fetch_html(url)
        live_results = parse_search_html(html)
    except Exception as e:
        print(f"[Search] Live search failed: {e}")
        
    # Always query local fuzzy search
    local_results = cache_manager.fuzzy_search(query)
    
    # Merge and deduplicate by slug
    merged = []
    seen = set()
    
    # Add live results first
    for item in live_results:
        slug = item.get('slug')
        if slug and slug not in seen:
            seen.add(slug)
            merged.append(item)
            
    # Add high-scoring local fuzzy results next
    for item in local_results:
        slug = item.get('slug')
        if slug and slug not in seen:
            seen.add(slug)
            merged.append(item)
            
    translated_data = translate_covers_in_obj(merged)
    
    # Trigger background upload for search results
    for item in merged:
        if item.get('thumb') and item.get('slug'):
            trigger_single_image_upload(item['thumb'], item['slug'])
            
    return jsonify({'success': True, 'data': translated_data, 'source': 'merged'})

@app.route('/api/schedule')
def api_schedule():
    """Fetch anime release schedule with 12 hours SWR cache"""
    try:
        def fetch():
            url = urllib.parse.urljoin(BASE_URL, "jadwal-rilis/")
            print(f"[Scraper] Fetching schedule from {url}...")
            html = fetch_html(url)
            return parse_schedule_html(html)
            
        data, status = cache_manager.get_data_swr("schedule", fetch, ttl_seconds=43200)
        translated_data = translate_covers_in_obj(data)
        return jsonify({'success': True, 'data': translated_data, 'cache_status': status})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/genres')
def api_genres():
    """Fetch all genres with 24 hours SWR cache"""
    try:
        def fetch():
            url = urllib.parse.urljoin(BASE_URL, "genre-list/")
            print(f"[Scraper] Fetching genres from {url}...")
            html = fetch_html(url)
            return parse_genres_html(html)
            
        data, status = cache_manager.get_data_swr("genres", fetch, ttl_seconds=86400)
        translated_data = translate_covers_in_obj(data)
        if isinstance(translated_data, list):
            translated_data = [g for g in translated_data if g.get('slug') != 'hentai']
        return jsonify({'success': True, 'data': translated_data, 'cache_status': status})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/genres/<slug>')
def api_genre_detail(slug):
    """Fetch anime list by genre with SWR cache and pagination support"""
    page = request.args.get('page', 1, type=int)
    try:
        if slug == 'hentai':
            return jsonify({'success': False, 'message': 'Genre ini tidak tersedia.'}), 404

        def fetch():
            if page == 1:
                url = urllib.parse.urljoin(BASE_URL, f"genres/{slug}/")
            else:
                url = urllib.parse.urljoin(BASE_URL, f"genres/{slug}/page/{page}/")
            print(f"[Scraper] Fetching genre list for '{slug}' page {page} from {url}...")
            html = fetch_html(url)
            return parse_genre_detail_html(html)
            
        data, status = cache_manager.get_data_swr(f"genre_{slug}_page_{page}", fetch, ttl_seconds=14400)
        try:
            data = enrich_anime_items(data)
        except Exception as e:
            print(f"Error enriching genre list: {e}")
        translated_data = translate_covers_in_obj(data)
        
        for item in data:
            if item.get('thumb') and item.get('slug'):
                trigger_single_image_upload(item['thumb'], item['slug'])
                
        return jsonify({'success': True, 'data': translated_data, 'cache_status': status})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/anime-list')
def api_anime_list():
    """Fetch complete A-Z anime list with 24 hours SWR cache"""
    try:
        def fetch():
            url = urllib.parse.urljoin(BASE_URL, "anime-list-2/")
            print(f"[Scraper] Fetching anime list from {url}...")
            html = fetch_html(url)
            return parse_anime_list_html(html)
            
        data, status = cache_manager.get_data_swr("anime_list", fetch, ttl_seconds=86400)
        translated_data = translate_covers_in_obj(data)
        return jsonify({'success': True, 'data': translated_data, 'cache_status': status})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

def resolve_direct_stream_url(iframe_url):
    """
    Scrape and decrypt the direct stream URL (.mp4 or .m3u8) from the embed page.
    Supports Filedon (Cloudflare R2 mp4 extraction) and Vidhide/Playmogo/Vembed (eval packed HLS extraction).
    """
    import html
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/115.0',
        'Referer': 'https://otakudesu.blog/'
    }
    
    def decode_packer(p, a, c, k):
        def baseN(num, b):
            if num == 0:
                return "0"
            digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            res = ""
            while num > 0:
                res = digits[num % b] + res
                num //= b
            return res

        for i in range(c - 1, -1, -1):
            if i < len(k) and k[i]:
                word = baseN(i, a)
                pattern = r'\b' + re.escape(word) + r'\b'
                p = re.sub(pattern, k[i], p)
        return p

    try:
        parsed_url = urllib.parse.urlparse(iframe_url)
        domain = parsed_url.netloc.lower()
        
        # 1. Filedon resolver
        if 'filedon' in domain:
            r = requests.get(iframe_url, headers=headers, timeout=5)
            if r.status_code == 200:
                match = re.search(r'id="app"\s+data-page="([^"]+)"', r.text)
                if match:
                    escaped_json = match.group(1)
                    json_str = html.unescape(escaped_json)
                    data = json.loads(json_str)
                    direct_url = data.get('props', {}).get('url')
                    if direct_url:
                        return direct_url
                        
        # 2. Desustream / Blogger resolver (Ondesu/Mega fallback mirrors)
        elif 'desustream' in domain:
            try:
                # Try json mode first to get active blogger link
                json_url = iframe_url + "&mode=json"
                r = requests.get(json_url, headers=headers, timeout=5)
                if r.status_code == 200:
                    data = r.json()
                    video_url = data.get('video')
                    if video_url and 'token=' in video_url and not video_url.endswith('token='):
                        return video_url
            except Exception:
                pass
                
            # Fallback to HTML parse
            r = requests.get(iframe_url, headers=headers, timeout=5)
            if r.status_code == 200:
                soup = BeautifulSoup(r.text, 'html.parser')
                iframe = soup.find('iframe', id='myIframe')
                if iframe and iframe.get('src'):
                    src = iframe.get('src')
                    if src and 'token=' in src and not src.endswith('token='):
                        return src

        # 3. Vidhide/Playmogo/Packer-based HLS resolver
        # We fetch the HTML and check if it contains the eval packer block.
        # This works generically for any host that uses Dean Edwards packer.
        r = requests.get(iframe_url, headers=headers, timeout=5)
        if r.status_code == 200:
            match = re.search(r"eval\(function\(p,a,c,k,e,d\).*?return p\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)", r.text)
            if match:
                p = match.group(1)
                a = int(match.group(2))
                c = int(match.group(3))
                k = match.group(4).split('|')
                decoded = decode_packer(p, a, c, k)
                
                # Parse links JSON object from decoded js
                links_match = re.search(r'var\s+links\s*=\s*(\{.*?\});', decoded)
                if links_match:
                    try:
                        links_data = json.loads(links_match.group(1))
                        for key in ['hls4', 'hls3', 'hls2']:
                            link_val = links_data.get(key)
                            if link_val:
                                if link_val.startswith('/'):
                                    scheme = parsed_url.scheme or 'https'
                                    link_val = f"{scheme}://{parsed_url.netloc}{link_val}"
                                return link_val
                    except Exception:
                        pass
                
                # Fallback matching for any m3u8 or mp4
                urls = re.findall(r'https?://[^\s"\',>]+', decoded)
                for u in urls:
                    if '.m3u8' in u or '.mp4' in u:
                        return u
    except Exception as e:
        print(f"[DirectResolver] Error resolving {iframe_url}: {e}")
        
    return None

@app.route('/api/stream')
def api_stream():
    """
    Resolve mirror stream iframe URL.
    Verifies link availability. If 504/404 or fails, removes cache of episode
    and falls back to alternative mirror automatically!
    """
    episode_slug = request.args.get('episode_slug')
    content_payload = request.args.get('content') # base64 string or raw URL
    
    if not episode_slug or not content_payload:
        return jsonify({'success': False, 'message': 'Missing parameters'}), 400
        
    try:


        # Check DB first
        db_entry = cache_manager.get_episode_detail(episode_slug)
        if db_entry:
            ep_data = db_entry['data']
        else:
            def fetch_ep():
                url = urllib.parse.urljoin(BASE_URL, f"episode/{episode_slug}/")
                html = fetch_html(url)
                return parse_episode_html(html, episode_slug)
                
            ep_data, _ = cache_manager.get_data_swr(f"episode_{episode_slug}", fetch_ep, ttl_seconds=3600)
            if ep_data:
                cache_manager.set_episode_detail(episode_slug, ep_data)
        
        action_nonce = ep_data.get('action_nonce', 'aa1208d27f29ca340c92c66d1926f13f')
        action_stream = ep_data.get('action_stream', '2a3505c93b0035d3f455df82bf976b84')
        mirrors = ep_data.get('mirrors', [])
        
        # Helper function to resolve individual mirror data-content payload
        def fetch_iframe_from_ajax(content_str):
            decoded_b64 = base64.b64decode(content_str).decode('utf-8')
            params = json.loads(decoded_b64)
            
            session = requests.Session()
            session.headers.update(get_headers(referer=urllib.parse.urljoin(BASE_URL, f"episode/{episode_slug}/")))
            
            # Step A: Get AJAX session nonce
            payload_nonce = {'action': action_nonce}
            r_nonce = session.post(AJAX_URL, data=payload_nonce, timeout=5)
            if r_nonce.status_code != 200:
                raise Exception("Failed to get AJAX session nonce")
                
            nonce_res = r_nonce.json()
            nonce = nonce_res.get('data')
            if not nonce:
                raise Exception("Missing nonce data")
                
            # Step B: Get the encrypted HTML stream
            payload_stream = {
                **params,
                'nonce': nonce,
                'action': action_stream
            }
            r_stream = session.post(AJAX_URL, data=payload_stream, timeout=5)
            if r_stream.status_code != 200:
                raise Exception("Failed to fetch stream data from AJAX")
                
            stream_res = r_stream.json()
            enc_html = stream_res.get('data')
            if not enc_html:
                raise Exception("No encrypted iframe data received")
                
            dec_html = base64.b64decode(enc_html).decode('utf-8')
            soup = BeautifulSoup(dec_html, 'html.parser')
            iframe = soup.find('iframe')
            if iframe and iframe.get('src'):
                return iframe.get('src')
            raise Exception("No iframe found in resolved HTML")

        # 2. Find requested mirror index or match
        target_content = content_payload
        idx = -1
        for i, m in enumerate(mirrors):
            if m['content'] == target_content:
                idx = i
                break
                
        if idx == -1:
            # Fallback to the first mirror if content parameter mismatch
            if mirrors:
                idx = 0
                target_content = mirrors[0]['content']
            else:
                # Return default stream from detail page
                if ep_data.get('default_stream'):
                    return jsonify({'success': True, 'stream_url': ep_data['default_stream'], 'source': 'default_fallback'})
                return jsonify({'success': False, 'message': 'No mirrors found for episode'}), 404
                
        # 3. Resolve loop with verification fallback
        resolved_src = None
        working_mirror_name = "Requested Mirror"
        
        while idx < len(mirrors):
            m = mirrors[idx]
            working_mirror_name = f"{m['name']} ({m['resolution']})"
            print(f"[StreamResolver] Resolving mirror {idx}: {working_mirror_name}...")
            
            try:
                # Get iframe URL
                iframe_url = fetch_iframe_from_ajax(m['content'])
                
                # Verify link availability by sending a fast request
                print(f"[StreamResolver] Verifying streaming iframe URL: {iframe_url}...")
                test_headers = get_headers(referer=urllib.parse.urljoin(BASE_URL, f"episode/{episode_slug}/"))
                
                # Check status
                chk = requests.head(iframe_url, headers=test_headers, allow_redirects=True, timeout=3)
                if chk.status_code in [404, 502, 503, 504]:
                    raise Exception(f"Server returned HTTP status {chk.status_code}")
                    
                # If everything passes
                resolved_src = iframe_url
                break
            except Exception as ex:
                print(f"[StreamResolver] Mirror '{working_mirror_name}' FAILED: {ex}")
                # Evict this episode's cache to get clean mirrors list next scrape
                cache_manager.delete(f"episode_{episode_slug}")
                cache_manager.delete_episode_detail(episode_slug)
                # Fallback to next mirror
                idx += 1
                if idx < len(mirrors):
                    print(f"[StreamResolver] Falling back to mirror {idx}: {mirrors[idx]['name']}...")
                else:
                    print("[StreamResolver] All mirrors exhausted.")
                    
        # 4. Final output
        if resolved_src:
            direct_url = resolve_direct_stream_url(resolved_src)
            return jsonify({
                'success': True,
                'stream_url': resolved_src,
                'direct_url': direct_url,
                'mirror_name': working_mirror_name,
                'resolution': mirrors[idx]['resolution'] if idx < len(mirrors) else 'N/A',
                'fallback_triggered': idx > 0
            })
            
        # If all mirrors fail, fallback to the page's default iframe player (if it is working)
        default_iframe = ep_data.get('default_stream')
        if default_iframe:
            print("[StreamResolver] All mirrors failed. Falling back to default embed stream...")
            return jsonify({
                'success': True,
                'stream_url': default_iframe,
                'mirror_name': 'Default Player',
                'resolution': 'Default',
                'fallback_triggered': True,
                'warning': 'All premium mirrors are offline. Loaded default player.'
            })
            
        return jsonify({'success': False, 'message': 'All streaming servers are currently offline (502/404)'}), 502
        
    except Exception as e:
        return jsonify({'success': False, 'message': f"Failed resolving stream: {str(e)}"}), 500

def is_safe_proxy_url(url_str):
    try:
        parsed = urllib.parse.urlparse(url_str)
        if parsed.scheme not in ('http', 'https'):
            return False
        hostname = parsed.hostname
        if not hostname:
            return False
            
        # Block private and loopback IPs
        import ipaddress
        try:
            ip = ipaddress.ip_address(hostname)
            if ip.is_loopback or ip.is_private or ip.is_link_local:
                return False
        except ValueError:
            # Not an IP address, check for common bypass hostnames like 'localhost'
            if hostname.lower() in ('localhost', 'localhost.localdomain'):
                return False
                
        # To be extra safe, restrict proxying to known safe video / image streaming host suffixes
        allowed_suffixes = (
            '.otakudesu.blog', '.otakudesu.cloud', '.otakudesu.asia', '.otakudesu.co', '.otakudesu.my', '.otakudesu.live', '.otakudesu.icu', '.otakudesu.pro', '.otakudesu.xyz', '.otakudesu.top',
            '.filedon.club', '.filedon.co', '.filedon.cx', '.filedon.to',
            '.desustream.me', '.desustream.xyz', '.desustream.co',
            '.googlevideo.com', '.blogspot.com', '.blogger.com',
            '.vidhide.com', '.vidhide.pro', '.vidhide.co', '.vidhide.xyz', '.vidhide.to',
            '.playmogo.com', '.playmogo.xyz', '.playmogo.to',
            '.telegram.org', '.api.telegram.org', '.komiku.org', '.komiku.co.id',
            'otakudesu.blog', 'otakudesu.cloud', 'otakudesu.asia', 'otakudesu.co', 'otakudesu.my', 'otakudesu.live', 'otakudesu.icu', 'otakudesu.pro', 'otakudesu.xyz', 'otakudesu.top',
            'filedon.club', 'filedon.co', 'filedon.cx', 'filedon.to',
            'desustream.me', 'desustream.xyz', 'desustream.co',
            'googlevideo.com', 'blogspot.com', 'blogger.com',
            'vidhide.com', 'vidhide.pro', 'vidhide.co', 'vidhide.xyz', 'vidhide.to',
            'playmogo.com', 'playmogo.xyz', 'playmogo.to',
            'telegram.org', 'api.telegram.org', 'komiku.org', 'komiku.co.id'
        )
        hostname_lower = hostname.lower()
        
        # Check if hostname ends with any of the allowed suffixes
        if any(hostname_lower == suffix or hostname_lower.endswith(suffix) for suffix in allowed_suffixes):
            return True
            
        # Fallback: log warning and deny unknown external domains
        print(f"[SSRF Protection] Blocked proxy request to unknown host: {hostname}")
        return False
    except Exception:
        return False

@app.route('/api/proxy')
def api_proxy():
    """
    Reverse proxy endpoint to stream or load files bypassing strict referer policies.
    """
    url = request.args.get('url')
    referrer = request.args.get('referrer', 'https://otakudesu.blog/')
    
    if not url:
        return 'Missing url parameter', 400
        
    try:
        url_decoded = urllib.parse.unquote(url)
        
        # Verify if the target URL is safe to prevent SSRF
        if not is_safe_proxy_url(url_decoded):
            return 'Forbidden: Target URL is not allowed', 403
            
        headers = get_headers(referer=referrer)
        
        # Fetch target stream/page
        r = requests.get(url_decoded, headers=headers, stream=True, timeout=10)
        
        excluded_headers = ['content-encoding', 'content-length', 'transfer-encoding', 'connection']
        headers_to_forward = [(k, v) for k, v in r.headers.items() if k.lower() not in excluded_headers]
        headers_to_forward.append(('Access-Control-Allow-Origin', '*'))
        
        return Response(r.iter_content(chunk_size=4096), status=r.status_code, headers=headers_to_forward)
    except Exception as e:
        return str(e), 500

@app.route('/', defaults={'path': ''})
@app.route('/<path:path>')
def serve_frontend(path):
    if path.startswith('api/'):
        return jsonify({'success': False, 'message': 'API Route not found'}), 404
    
    # Block direct access to frontend UI on Flask port (e.g., localhost:5000)
    # Only allow access if the request goes through Nginx (which sets proxy headers)
    if os.environ.get('NO_NGINX') != 'true' and not request.headers.get('X-Forwarded-For') and not request.headers.get('X-Real-IP'):
        return Response(
            "Access forbidden: Direct access to backend port is not allowed. Please use the Nginx entry point.",
            status=403,
            mimetype="text/plain"
        )

    # Do not serve index.html for missing assets
    if path.startswith('assets/'):
        file_path = os.path.join(STATIC_FOLDER, path)
        if os.path.exists(file_path) and os.path.isfile(file_path):
            return send_from_directory(STATIC_FOLDER, path)
        return 'Asset not found', 404
    file_path = os.path.join(STATIC_FOLDER, path)
    if path and os.path.exists(file_path) and os.path.isfile(file_path):
        return send_from_directory(STATIC_FOLDER, path)
    return send_from_directory(STATIC_FOLDER, 'index.html')

if __name__ == '__main__':
    # Start startup uploads in a background thread to prevent blocking Flask boot
    # WERKZEUG_RUN_MAIN ensures it only runs once under Flask's debug reloader
    if os.environ.get('WERKZEUG_RUN_MAIN') == 'true' or not app.debug:
        def run_startup_jobs():
            time.sleep(3)
            resume_pending_uploads()
            upload_all_missing_covers()
            
        threading.Thread(target=run_startup_jobs, daemon=True).start()

    # Run backend Flask server on port 5000
    app.run(host='127.0.0.1', port=5000, debug=False)

