import sqlite3
import math
import struct

DB_PATH = "/Users/olli/Library/Application Support/com.musiclibrary.app/music_library.db"

def parse_blob(blob):
    if not blob:
        return []
    n = len(blob) // 4
    return list(struct.unpack(f'{n}f', blob))

def cosine_similarity(v1, v2):
    if not v1 or not v2 or len(v1) != len(v2):
        return 0.0
    dot = sum(a * b for a, b in zip(v1, v2))
    mag1 = math.sqrt(sum(a * a for a in v1))
    mag2 = math.sqrt(sum(b * b for b in v2))
    if mag1 == 0 or mag2 == 0:
        return 0.0
    return dot / (mag1 * mag2)

def calculate_score(seed, cand, w_groove, w_dance, w_energy, w_genre):
    total_weight = 0.0
    weighted_score = 0.0
    
    # 1. Groove (CoreML Embedding)
    if w_groove > 0:
        base_cosine = cosine_similarity(seed['embedding'], cand['embedding'])
        weighted_score += base_cosine * w_groove
        total_weight += w_groove
        
    # 2. Danceability
    if seed['danceability'] is not None and cand['danceability'] is not None:
        if seed['danceability'] == 0.0 and cand['danceability'] == 0.0:
            dance_score = 0.5
        else:
            diff = abs(seed['danceability'] - cand['danceability'])
            dance_score = 1.0 - diff
            
        weighted_score += dance_score * w_dance
        total_weight += w_dance
        
    # 3. Energy (LUFS)
    if seed['lufs_i'] is not None and cand['lufs_i'] is not None:
        diff = abs(seed['lufs_i'] - cand['lufs_i'])
        energy_score = math.exp(-diff / 4.0)
        weighted_score += energy_score * w_energy
        total_weight += w_energy
        
    # 4. Genre
    s_genre = seed['genre'].lower().strip()
    c_genre = cand['genre'].lower().strip()
    
    if s_genre and c_genre:
        genre_score = 0.1 # penalize mismatched genres
        if s_genre == c_genre:
            genre_score = 1.0
        elif ('house' in s_genre and 'house' in c_genre) or \
             ('rap' in s_genre and 'rap' in c_genre) or \
             ('club' in s_genre and 'club' in c_genre):
            genre_score = 0.8
            
        weighted_score += genre_score * w_genre
        total_weight += w_genre
        
    return weighted_score / total_weight if total_weight > 0 else 0.0

def run_test(conn, seed_id, w_groove, w_dance, w_energy, w_genre):
    cursor = conn.cursor()
    
    query = """
        SELECT t.id, t.artist, t.title, t.genre, t.danceability, t.lufs_i, e.master_embedding, e.mix_category
        FROM tracks t
        JOIN track_embeddings e ON t.id = e.track_id
        WHERE t.danceability IS NOT NULL AND t.lufs_i IS NOT NULL;
    """
    rows = cursor.execute(query).fetchall()
    
    tracks = []
    seed = None
    for r in rows:
        t = {
            'id': r['id'],
            'artist': r['artist'],
            'title': r['title'],
            'genre': r['genre'] or "",
            'danceability': r['danceability'],
            'lufs_i': r['lufs_i'],
            'embedding': parse_blob(r['master_embedding']),
            'mix_category': r['mix_category']
        }
        if t['id'] == seed_id:
            seed = t
        tracks.append(t)
        
    if not seed:
        print(f"Seed ID {seed_id} not found!")
        return
        
    print("\n" + "="*80)
    print(f"SEED: {seed['artist']} - {seed['title']} [{seed['genre']}] (Danceability: {seed['danceability']:.3f}, LUFS: {seed['lufs_i']:.2f})")
    print(f"Weights Config: Groove={w_groove*100}%, Dance={w_dance*100}%, Energy={w_energy*100}%, Genre={w_genre*100}%")
    print("="*80)
    
    scored_candidates = []
    for cand in tracks:
        if cand['id'] == seed['id']:
            continue
        if seed['mix_category'] != cand['mix_category']:
            continue
            
        score = calculate_score(seed, cand, w_groove, w_dance, w_energy, w_genre)
        
        base_cosine = cosine_similarity(seed['embedding'], cand['embedding'])
        diff_dance = abs(seed['danceability'] - cand['danceability'])
        dance_score = 0.5 if (seed['danceability'] == 0.0 and cand['danceability'] == 0.0) else (1.0 - diff_dance)
        diff_lufs = abs(seed['lufs_i'] - cand['lufs_i'])
        energy_score = math.exp(-diff_lufs / 4.0)
        
        scored_candidates.append({
            'track': cand,
            'score': score,
            'base_cosine': base_cosine,
            'dance_score': dance_score,
            'energy_score': energy_score
        })
        
    scored_candidates.sort(key=lambda x: x['score'], reverse=True)
    
    for idx, item in enumerate(scored_candidates[:10]):
        cand = item['track']
        print(f"{idx+1}. [{item['score']:.3f}] {cand['artist']} - {cand['title']} [{cand['genre']}]")
        print(f"   Breakdown -> Cosine: {item['base_cosine']:.3f} | Dance Match: {item['dance_score']:.3f} | Energy Match: {item['energy_score']:.3f}")

def main():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    # Fetch a real Vixa track
    row = cursor.execute("SELECT id FROM tracks WHERE genre LIKE '%vixa%' LIMIT 1;").fetchone()
    if not row:
        print("No Vixa track found in database!")
        return
    seed_id = row['id']
    
    print("\n--- RUNNING VIXA SEED WITH CURRENT METRIC (40% GROOVE) ---")
    run_test(conn, seed_id, 0.40, 0.30, 0.20, 0.10)
    
    print("\n--- RUNNING VIXA SEED WITH NO-GROOVE METRIC (Dance=40%, Energy=40%, Genre=20%) ---")
    run_test(conn, seed_id, 0.00, 0.40, 0.40, 0.20)
    
    conn.close()

if __name__ == '__main__':
    main()
