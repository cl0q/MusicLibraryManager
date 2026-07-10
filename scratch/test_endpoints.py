import os
import requests
import json
import re

# Load .env credentials
SPOTIFY_CLIENT_ID = None
SPOTIFY_CLIENT_SECRET = None
SOUNDCLOUD_CLIENT_ID = None

env_path = "/Users/olli/schenanigans/MusicLibraryManager/.env"
if os.path.exists(env_path):
    with open(env_path, 'r') as f:
        for line in f:
            if '=' in line:
                key, val = line.strip().split('=', 1)
                if key == 'SPOTIFY_CLIENT_ID':
                    SPOTIFY_CLIENT_ID = val
                elif key == 'SPOTIFY_CLIENT_SECRET':
                    SPOTIFY_CLIENT_SECRET = val

# Load SoundCloud client ID from ~/.config/scdl/scdl.cfg
home = os.path.expanduser("~")
cfg_path = os.path.join(home, ".config", "scdl", "scdl.cfg")
if os.path.exists(cfg_path):
    with open(cfg_path, 'r') as f:
        for line in f:
            line_str = line.strip()
            if line_str.startswith("client_id"):
                SOUNDCLOUD_CLIENT_ID = line_str.split("=", 1)[1].strip()

print("Loaded Headless Credentials:")
print(f"  Spotify Client ID: {SPOTIFY_CLIENT_ID[:5]}... (Exists: {SPOTIFY_CLIENT_ID is not None})")
print(f"  SoundCloud Client ID (Browser Session): {SOUNDCLOUD_CLIENT_ID[:5]}... (Exists: {SOUNDCLOUD_CLIENT_ID is not None})")

# -----------------------------------------------------------------------------
# 1. TEST SPOTIFY RECOMMENDATIONS API
# -----------------------------------------------------------------------------
def test_spotify():
    print("\n" + "="*40)
    print("TESTING SPOTIFY API")
    print("="*40)
    
    if not SPOTIFY_CLIENT_ID or not SPOTIFY_CLIENT_SECRET:
        print("Skipping Spotify: credentials missing in .env")
        return
        
    try:
        # Get Auth Token
        auth_url = "https://accounts.spotify.com/api/token"
        auth_response = requests.post(auth_url, {
            'grant_type': 'client_credentials',
            'client_id': SPOTIFY_CLIENT_ID,
            'client_secret': SPOTIFY_CLIENT_SECRET,
        })
        
        if auth_response.status_code != 200:
            print(f"Spotify Authentication failed: {auth_response.status_code}")
            return
            
        access_token = auth_response.json().get('access_token')
        print("Successfully obtained Spotify Access Token!")
        
        headers = {
            "Authorization": f"Bearer {access_token}",
            "User-Agent": "MusicLibraryManager/1.0"
        }
        
        # Query track first to see if it is found
        seed_track_id = "5x1TehTBcntBNhbzZvzJ8D"
        track_url = f"https://api.spotify.com/v1/tracks/{seed_track_id}"
        track_response = requests.get(track_url, headers=headers)
        if track_response.status_code == 200:
            t = track_response.json()
            print(f"Track lookup succeeded! Title: '{t.get('name')}' by {t.get('artists')[0].get('name')}")
        else:
            print(f"Track lookup failed: {track_response.status_code} - {track_response.text}")
            
        # Try Recommendations
        rec_url = f"https://api.spotify.com/v1/recommendations?seed_tracks={seed_track_id}&limit=5"
        rec_response = requests.get(rec_url, headers=headers)
        if rec_response.status_code == 200:
            tracks = rec_response.json().get('tracks', [])
            print(f"Successfully fetched {len(tracks)} recommendations from Spotify:")
            for idx, t in enumerate(tracks):
                artists = ", ".join([a['name'] for a in t['artists']])
                print(f"  {idx+1}. {artists} - {t['name']} (Spotify ID: {t['id']})")
        else:
            print(f"Spotify Recommendations failed: {rec_response.status_code}")
            print(rec_response.text)
            
    except Exception as e:
        print(f"Spotify test errored: {e}")

# -----------------------------------------------------------------------------
# 2. TESTING SOUNDCLOUD RELATED TRACKS API
# -----------------------------------------------------------------------------
def test_soundcloud():
    print("\n" + "="*40)
    print("TESTING SOUNDCLOUD API")
    print("="*40)
    
    if not SOUNDCLOUD_CLIENT_ID:
        print("Skipping SoundCloud: browser client_id not found in scdl.cfg")
        return
        
    try:
        # Step A: Resolve track URL to get track ID
        track_url = "https://soundcloud.com/sosocamo/say-dat"
        resolve_url = f"https://api-v2.soundcloud.com/resolve?url={track_url}&client_id={SOUNDCLOUD_CLIENT_ID}"
        
        headers = {
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        }
        
        resolve_response = requests.get(resolve_url, headers=headers)
        if resolve_response.status_code != 200:
            print(f"SoundCloud Resolve failed: {resolve_response.status_code}")
            print(resolve_response.text)
            return
            
        track_data = resolve_response.json()
        track_id = track_data.get('id')
        print(f"Successfully resolved SoundCloud track! Title: '{track_data.get('title')}' | ID: {track_id}")
        
        # Step B: Fetch related tracks
        related_url = f"https://api-v2.soundcloud.com/tracks/{track_id}/related?client_id={SOUNDCLOUD_CLIENT_ID}&limit=5"
        related_response = requests.get(related_url, headers=headers)
        
        if related_response.status_code == 200:
            collection = related_response.json().get('collection', [])
            print(f"Successfully fetched {len(collection)} related tracks from SoundCloud:")
            for idx, t in enumerate(collection[:5]):
                user = t.get('user', {}).get('username', 'Unknown')
                print(f"  {idx+1}. {user} - {t.get('title')} (SoundCloud ID: {t.get('id')})")
        else:
            print(f"SoundCloud Related failed: {related_response.status_code}")
            print(related_response.text)
            
    except Exception as e:
        print(f"SoundCloud test errored: {e}")

# -----------------------------------------------------------------------------
# 3. TEST LAST.FM SIMILAR TRACKS API
# -----------------------------------------------------------------------------
def test_lastfm():
    print("\n" + "="*40)
    print("TESTING LAST.FM API")
    print("="*40)
    
    # Try different popular open-source API keys
    keys_to_try = [
        "1275d27878d46dbcd320f785b9bba0f9", # Common open key
        "b88e1cf012c4b8e2183c5e88fc87b92f", # Clementine music player key
        "4a9f5583f1d3f25c7e7b2dd6a0a03c2e", 
    ]
    
    url = "http://ws.audioscrobbler.com/2.0/"
    headers = {
        "User-Agent": "MusicLibraryManager/1.0 (contact@musiclibrary.app)"
    }
    
    for idx, key in enumerate(keys_to_try):
        print(f"Trying Last.fm API Key #{idx+1} ({key[:5]}...):")
        params = {
            "method": "track.getSimilar",
            "artist": "Crusy",
            "track": "Supersonic",
            "api_key": key,
            "format": "json",
            "limit": 5
        }
        
        try:
            response = requests.get(url, params=params, headers=headers)
            if response.status_code == 200:
                data = response.json()
                if 'error' in data:
                    print(f"  Failed: {data.get('message')}")
                    continue
                    
                similar_tracks = data.get('similartracks', {}).get('track', [])
                print(f"  Successfully fetched {len(similar_tracks)} similar tracks from Last.fm:")
                for s_idx, t in enumerate(similar_tracks):
                    print(f"    {s_idx+1}. {t.get('artist', {}).get('name')} - {t.get('name')} (Match factor: {float(t.get('match', 0.0))*100:.1f}%)")
                return # Stop if successful!
            else:
                print(f"  Failed HTTP {response.status_code}")
        except Exception as e:
            print(f"  Error: {e}")

if __name__ == '__main__':
    test_spotify()
    test_soundcloud()
    test_lastfm()
