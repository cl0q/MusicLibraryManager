#!/usr/bin/env python3
"""
M3U8 Playlist Converter - Fuzzy matches playlist tracks to a target music directory.
"""

import argparse
import os
import re
import sys
from pathlib import Path
from rapidfuzz import fuzz
from colorama import Fore, Style, init

init(autoreset=True)


def parse_m3u8(file_path: str) -> list[str]:
    """Parse an M3U8 playlist file and return list of track paths."""
    tracks = []
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                tracks.append(line)
    return tracks


def find_all_music_files(directory: str) -> list[str]:
    """Recursively find all music files in directory."""
    music_extensions = {'.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.aiff', '.wma', '.alac'}
    music_files = []
    
    for root, _, files in os.walk(directory):
        for file in files:
            if Path(file).suffix.lower() in music_extensions:
                music_files.append(os.path.join(root, file))
    
    return music_files


def extract_track_name(track_path: str) -> str:
    """Extract just the filename from a track path."""
    return Path(track_path).name


def normalize_filename(filename: str) -> str:
    """Normalize a filename by removing track numbers, extensions, and extra spaces."""
    # Remove file extension
    name_without_ext = Path(filename).stem
    # Remove leading track numbers like "80 - ", "01 - ", etc.
    normalized = re.sub(r'^\d+\s*[-._]\s*', '', name_without_ext.lower())
    # Collapse multiple spaces and separators
    normalized = re.sub(r'\s+', ' ', normalized).strip()
    return normalized


def extract_key_tokens(filename: str) -> set[str]:
    """Extract key identifying tokens from a filename."""
    normalized = normalize_filename(filename)
    # Split on spaces
    tokens = set(normalized.split())
    # Remove very short tokens (1-2 chars) and pure numbers
    tokens = {t for t in tokens if len(t) > 2 and not t.isdigit()}
    return tokens


def calculate_word_overlap_score(track_name: str, music_name: str) -> float:
    """Calculate score based on word overlap between track and music filename."""
    track_tokens = extract_key_tokens(track_name)
    music_tokens = extract_key_tokens(music_name)
    
    if not track_tokens or not music_tokens:
        return 0
    
    # Calculate overlap
    overlap = track_tokens & music_tokens
    track_unique = len(track_tokens)
    
    if track_unique == 0:
        return 0
    
    # Score is percentage of track tokens found in music file
    overlap_ratio = len(overlap) / track_unique * 100
    
    # Bonus for matching all tokens
    if overlap_ratio == 100:
        return 100
    
    return overlap_ratio


def find_best_match(track_name: str, music_files: list[str], threshold: int) -> tuple[str, int] | None:
    """Find the best fuzzy match for a track name in the music files list."""
    best_match = None
    best_score = 0
    
    track_tokens = extract_key_tokens(track_name)
    
    # Must have at least one meaningful token to match
    if not track_tokens:
        return None
    
    for music_file in music_files:
        music_name = extract_track_name(music_file)
        music_tokens = extract_key_tokens(music_name)
        
        # Require at least one token overlap
        token_overlap = track_tokens & music_tokens
        if not token_overlap:
            continue
        
        # Calculate multiple scores
        track_lower = track_name.lower()
        music_lower = music_name.lower()
        
        # Word overlap score (most important)
        word_score = calculate_word_overlap_score(track_name, music_name)
        
        # Token sort ratio
        token_score = fuzz.token_sort_ratio(track_lower, music_lower)
        
        # Partial ratio
        partial_score = fuzz.partial_ratio(track_lower, music_lower)
        
        # Combined score - word overlap is most important
        # Weight word overlap heavily (60%), fuzzy matching less (40%)
        combined_score = (word_score * 0.6) + (max(token_score, partial_score) * 0.4)
        
        # Require strong word overlap (at least 50% of track tokens must match)
        if word_score < 50:
            continue
        
        if combined_score > best_score and combined_score >= threshold:
            best_score = combined_score
            best_match = music_file
    
    if best_match:
        return (best_match, int(best_score))
    return None


def write_m3u8(file_path: str, tracks: list[str], header: str | None = None):
    """Write tracks to an M3U8 playlist file."""
    with open(file_path, 'w', encoding='utf-8') as f:
        if header:
            f.write(header + '\n')
        for track in tracks:
            f.write(track + '\n')


def main():
    parser = argparse.ArgumentParser(
        description='Convert M3U8 playlist by fuzzy matching tracks to a target music directory.',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument('input_playlist', help='Input M3U8 playlist file path')
    parser.add_argument('music_directory', help='Target music directory to search recursively')
    parser.add_argument('output_playlist', help='Output M3U8 playlist file path')
    parser.add_argument(
        '--fuzzy-confidence',
        type=int,
        default=90,
        help='Fuzzy match confidence threshold (0-100, default: 90)'
    )
    
    args = parser.parse_args()
    
    # Validate inputs
    if not os.path.isfile(args.input_playlist):
        print(Fore.RED + Style.BRIGHT + f"Error: Input playlist '{args.input_playlist}' not found." + Style.RESET_ALL)
        sys.exit(1)
    
    if not os.path.isdir(args.music_directory):
        print(Fore.RED + Style.BRIGHT + f"Error: Music directory '{args.music_directory}' not found." + Style.RESET_ALL)
        sys.exit(1)
    
    if args.fuzzy_confidence < 0 or args.fuzzy_confidence > 100:
        print(Fore.RED + Style.BRIGHT + "Error: Fuzzy confidence must be between 0 and 100." + Style.RESET_ALL)
        sys.exit(1)
    
    print(Fore.CYAN + Style.BRIGHT + "\n🎵 M3U8 Playlist Converter" + Style.RESET_ALL)
    print(Fore.CYAN + "=" * 50 + Style.RESET_ALL)
    print(f"{Fore.YELLOW}Input playlist:{Style.RESET_ALL} {args.input_playlist}")
    print(f"{Fore.YELLOW}Music directory:{Style.RESET_ALL} {args.music_directory}")
    print(f"{Fore.YELLOW}Output playlist:{Style.RESET_ALL} {args.output_playlist}")
    print(f"{Fore.YELLOW}Fuzzy confidence:{Style.RESET_ALL} {args.fuzzy_confidence}%\n")
    
    # Parse input playlist
    print(Fore.GREEN + Style.BRIGHT + "📋 Parsing input playlist..." + Style.RESET_ALL)
    tracks = parse_m3u8(args.input_playlist)
    print(f"  Found {Fore.CYAN}{len(tracks)}{Style.RESET_ALL} tracks\n")
    
    # Find all music files
    print(Fore.GREEN + Style.BRIGHT + "🔍 Scanning music directory..." + Style.RESET_ALL)
    music_files = find_all_music_files(args.music_directory)
    print(f"  Found {Fore.CYAN}{len(music_files)}{Style.RESET_ALL} music files\n")
    
    # Match tracks
    print(Fore.GREEN + Style.BRIGHT + "🎯 Matching tracks..." + Style.RESET_ALL)
    matched_tracks = []
    unmatched_tracks = []
    
    for i, track in enumerate(tracks, 1):
        track_name = extract_track_name(track)
        print(f"  [{i}/{len(tracks)}] {Fore.WHITE}{track_name}{Style.RESET_ALL}...", end=" ")
        
        result = find_best_match(track_name, music_files, args.fuzzy_confidence)
        
        if result:
            matched_file, score = result
            matched_tracks.append(matched_file)
            print(Fore.GREEN + f"✓ MATCH ({score}%)" + Style.RESET_ALL)
            print(f"    → {Fore.CYAN}{matched_file}{Style.RESET_ALL}")
        else:
            unmatched_tracks.append(track)
            print(Fore.RED + "✗ NO MATCH" + Style.RESET_ALL)
    
    # Summary
    print("\n" + Fore.CYAN + "=" * 50 + Style.RESET_ALL)
    print(Fore.GREEN + Style.BRIGHT + f"✓ Matched: {len(matched_tracks)}" + Style.RESET_ALL)
    print(Fore.RED + Style.BRIGHT + f"✗ Unmatched: {len(unmatched_tracks)}" + Style.RESET_ALL)
    
    # Write output
    if matched_tracks:
        print(f"\n{Fore.GREEN + Style.BRIGHT}💾 Writing output playlist..." + Style.RESET_ALL)
        write_m3u8(args.output_playlist, matched_tracks, "#EXTM3U")
        print(f"  Saved to: {Fore.CYAN}{args.output_playlist}{Style.RESET_ALL}")
    
    # Show unmatched tracks
    if unmatched_tracks:
        print(f"\n{Fore.YELLOW + Style.BRIGHT}⚠ Unmatched tracks:{Style.RESET_ALL}")
        for track in unmatched_tracks:
            print(f"  {Fore.RED}- {extract_track_name(track)}{Style.RESET_ALL}")
    
    print(f"\n{Fore.CYAN}Done!{Style.RESET_ALL}\n")


if __name__ == '__main__':
    main()