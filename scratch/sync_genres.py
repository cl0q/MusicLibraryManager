import os
import sqlite3
from mutagen import File
import sys

DB_PATH = "/Users/olli/Library/Application Support/com.musiclibrary.app/music_library.db"

def extract_genre(file_path):
    try:
        # Resolve symlinks or standard paths
        real_path = os.path.realpath(file_path)
        if not os.path.exists(real_path):
            return None
            
        audio = File(real_path, easy=True)
        genre = None
        
        if audio is not None and hasattr(audio, 'tags') and audio.tags:
            if 'genre' in audio.tags:
                val = audio.tags['genre']
                if val:
                    genre = val[0]
            elif '\xa9gen' in audio.tags:
                val = audio.tags['\xa9gen']
                if val:
                    genre = val[0]
                    
        if not genre:
            # Try without easy mode
            audio_raw = File(real_path)
            if audio_raw is not None and hasattr(audio_raw, 'tags') and audio_raw.tags:
                if 'genre' in audio_raw.tags:
                    val = audio_raw.tags['genre']
                    if val:
                        genre = val[0]
                elif '\xa9gen' in audio_raw.tags:
                    val = audio_raw.tags['\xa9gen']
                    if val:
                        genre = val[0]
                elif 'TCON' in audio_raw.tags: # MP3 raw ID3 genre frame
                    val = audio_raw.tags['TCON'].text
                    if val:
                        genre = val[0]
                        
        if genre:
            return str(genre).strip()
    except Exception as e:
        # Silent ignore for individual files
        pass
    return None

def main():
    if not os.path.exists(DB_PATH):
        print(f"Database path not found: {DB_PATH}")
        sys.exit(1)
        
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    # Fetch all local tracks
    query = "SELECT id, artist, title, genre, original_path, organized_path FROM tracks WHERE original_path LIKE '/%';"
    rows = cursor.execute(query).fetchall()
    
    print(f"Inspecting {len(rows)} local tracks in database...")
    
    updated_count = 0
    scanned_count = 0
    missing_files = 0
    
    # Batch updates for efficiency
    updates = []
    
    for r in rows:
        scanned_count += 1
        path = r['original_path']
        
        if not os.path.exists(path):
            missing_files += 1
            continue
            
        disk_genre = extract_genre(path)
        db_genre = r['genre'] or ""
        
        if disk_genre:
            # Standardize a bit
            disk_genre_clean = disk_genre.strip()
            if disk_genre_clean.lower() != db_genre.lower():
                updates.append((disk_genre_clean, r['id']))
                print(f"[{scanned_count}] UPDATE: {r['artist']} - {r['title']}")
                print(f"    Old DB Genre: '{db_genre}' -> New Disk Genre: '{disk_genre_clean}'")
                updated_count += 1
                
    if updates:
        print(f"\nWriting {len(updates)} genre updates to SQLite...")
        cursor.executemany("UPDATE tracks SET genre = ? WHERE id = ?;", updates)
        conn.commit()
        print("Successfully updated database!")
    else:
        print("\nNo genre updates needed (database is already in sync with files on disk).")
        
    print(f"\nSummary:")
    print(f"  Tracks Inspected: {scanned_count}")
    print(f"  Genres Updated:   {updated_count}")
    print(f"  Files Not Found:  {missing_files}")
    
    conn.close()

if __name__ == '__main__':
    main()
