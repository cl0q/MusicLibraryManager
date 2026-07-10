import sqlite3
import math
import struct
import sys

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

def main():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    # 1. Fetch tracks that have embeddings, danceability, and lufs
    query = """
        SELECT t.id, t.artist, t.title, t.genre, t.danceability, t.lufs_i, e.master_embedding, e.mix_category
        FROM tracks t
        JOIN track_embeddings e ON t.id = e.track_id
        WHERE t.danceability IS NOT NULL AND t.lufs_i IS NOT NULL
        LIMIT 2000;
    """
    rows = cursor.execute(query).fetchall()
    
    tracks = []
    for r in rows:
        tracks.append({
            'id': r['id'],
            'artist': r['artist'],
            'title': r['title'],
            'genre': r['genre'] or "",
            'danceability': r['danceability'],
            'lufs_i': r['lufs_i'],
            'embedding': parse_blob(r['master_embedding']),
            'mix_category': r['mix_category']
        })
        
    print(f"Loaded {len(tracks)} fully-analyzed tracks from database.")
    
    # 2. Find interesting seeds
    vixa_seed = None
    rap_seed = None
    house_seed = None
    
    for t in tracks:
        genre_lower = t['genre'].lower()
        if 'vixa' in genre_lower and not vixa_seed:
            vixa_seed = t
        elif ('rap' in genre_lower or 'hip' in genre_lower) and not rap_seed:
            rap_seed = t
        elif ('house' in genre_lower or 'techno' in genre_lower) and not house_seed:
            house_seed = t
            
    seeds = [("Vixa Seed", vixa_seed), ("Rap Seed", rap_seed), ("House/Techno Seed", house_seed)]
    
    for label, seed in seeds:
        if not seed:
            print(f"Could not find seed for {label}")
            continue
            
        print("\n" + "="*80)
        print(f"SEED: {seed['artist']} - {seed['title']} [{seed['genre']}]")
        print(f"      Danceability: {seed['danceability']:.3f} | LUFS-I: {seed['lufs_i']:.2f}")
        print(f"      Embedding classes representation (first 10 dims): {seed['embedding'][:10]}")
        print("="*80)
        
        # Calculate scores with all other tracks
        scored_candidates = []
        for cand in tracks:
            if cand['id'] == seed['id']:
                continue
                
            # Exclude mismatching mix categories
            if seed['mix_category'] != cand['mix_category']:
                continue
                
            base_cosine = cosine_similarity(seed['embedding'], cand['embedding'])
            
            # Replicate TrackRepository similarity ranking formula
            total_weight = 0.40
            weighted_score = base_cosine * 0.40
            
            # Danceability
            diff_dance = abs(seed['danceability'] - cand['danceability'])
            dance_score = 1.0 - diff_dance
            weighted_score += dance_score * 0.30
            total_weight += 0.30
            
            # Energy (LUFS)
            diff_lufs = abs(seed['lufs_i'] - cand['lufs_i'])
            energy_score = math.exp(-diff_lufs / 4.0)
            weighted_score += energy_score * 0.20
            total_weight += 0.20
            
            # Genre
            s_genre = seed['genre'].lower().strip()
            c_genre = cand['genre'].lower().strip()
            
            genre_score = 0.1 # Penalize completely mismatched genres
            if s_genre and c_genre:
                if s_genre == c_genre:
                    genre_score = 1.0
                elif ('house' in s_genre and 'house' in c_genre) or \
                     ('rap' in s_genre and 'rap' in c_genre) or \
                     ('club' in s_genre and 'club' in c_genre):
                    genre_score = 0.8
                weighted_score += genre_score * 0.10
                total_weight += 0.10
            
            final_score = weighted_score / total_weight if total_weight > 0 else 0.0
            
            scored_candidates.append({
                'track': cand,
                'score': final_score,
                'base_cosine': base_cosine,
                'dance_score': dance_score,
                'energy_score': energy_score,
                'genre_score': genre_score if (s_genre and c_genre) else None
            })
            
        # Sort descending
        scored_candidates.sort(key=lambda x: x['score'], reverse=True)
        
        print(f"Top 10 Recommendations for Seed:")
        for idx, item in enumerate(scored_candidates[:10]):
            cand = item['track']
            print(f"{idx+1}. [{item['score']:.3f}] {cand['artist']} - {cand['title']} [{cand['genre']}]")
            genre_str = f"{item['genre_score']:.1f}" if item['genre_score'] is not None else "N/A"
            print(f"   Breakdown -> Groove Cosine: {item['base_cosine']:.3f} | Dance Match: {item['dance_score']:.3f} | Energy Match: {item['energy_score']:.3f} | Genre Match: {genre_str}")
            
    conn.close()

if __name__ == '__main__':
    main()
