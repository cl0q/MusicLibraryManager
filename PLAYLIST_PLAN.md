# Plan: Remote-Playlist Browsen & Teil-Download (macOS-App)

> Gilt **nur** für `macos-app/`. Tauri (`src/`, `ui/`) bleibt unangetastet.

## Ziel

Der Nutzer kann Playlists von **SoundCloud**, **Spotify** und **YouTube** durchsuchen
und wahlweise **die ganze Playlist**, **die ersten N** oder **N zufällige** Lieder
herunterladen. Downloads gehen quellengetreu: SoundCloud-Playlists über SoundCloud
(scdl), YouTube-Playlists über yt-dlp, Spotify (kein Audio) über die Fallback-Kette.

## Rechercheergebnis (Doku)

- **scdl v3** = yt-dlp-Wrapper. Kein natives „erste N"/„random N", nur `-o` (Offset).
  → Wir laden nicht die Playlist am Stück, sondern **Track-für-Track** über die
  vorhandene `download(trackURL:)`-Methode.
- **yt-dlp**: `--flat-playlist -J` listet Playlists ohne Download (fürs Browsen);
  `--playlist-items 1:N` für Auswahl.
- **SoundCloud API**: `GET /playlists/{id}/tracks?linked_partitioning=1&limit=50`
  (paginiert via `next_href`). Jeder Track hat `permalink_url`.
- **Spotify API**: `GET /playlists/{id}/tracks?fields=...&limit=100&offset=` — nur
  Metadaten, **kein** Audio-Download (DRM).

## Kernidee (für alle Quellen gleich)

1. **Playlist als JSON ziehen** — geordnete Trackliste über die API/CLI holen.
2. **Lokal auswählen** — `.all` / `.firstN(n)` / `.randomN(n)` auf der geordneten Liste.
3. **Iterativ downloaden** — jede Auswahl als einzelne `DownloadRequest` durch den
   bestehenden `DownloadOrchestrator.downloadBatch` schicken (Fortschritt, Cancel,
   Dedup, Analyse laufen dann über den Standardpfad).

## Phase 0 — Quell-Pinning im Orchestrator (Voraussetzung)

Damit SC-Tracks garantiert über SC gehen (nicht bei scdl-Fehler auf DAB/Squid/YT
durchfallen) und YT-Tracks direkt über yt-dlp:

- `DownloadOrchestrator.DownloadRequest` bekommt `preferredSource: PreferredSource`
  (Enum: `.auto`, `.soundcloud`, `.youtube`; Default `.auto`).
- `downloadWithFallback` respektiert es:
  - `.soundcloud` → nur scdl mit der Track-URL, **kein** Querfallback.
  - `.youtube` → direkt `youtubeDownloader.downloadByURL(...)`, überspringt SC/DAB/Squid.
  - `.auto` → bisherige Kette (unverändert für Library-Downloads).
- `DownloadViewModel` bekommt optional einen `preferredSource`-Parameter, der an die
  Requests durchgereicht wird. Bestehende Aufrufe bleiben `.auto`.

## Phase A — SoundCloud (zuerst)

1. **`SoundCloudClient.fetchPlaylistTracks(playlistId:)`** — `/playlists/{id}/tracks`
   mit `linked_partitioning`, paginiert; liefert `[SoundCloudTrack]` in Reihenfolge.
2. **`syncSinglePlaylist(...)` echt implementieren** — Playlist als source-verlinkte
   MLM-Playlist anlegen (via `PlaylistRepository`), Tracks als remote upserten
   (Upsert-Logik aus `syncLikes` wiederverwenden), Reihenfolge via `replaceTrackList`.
3. **`fetchPlaylists()`** — schlanke Liste (Name, Cover, Trackzahl) fürs Browsen,
   ohne alle Tracks sofort zu laden.

## Phase B — Auswahl-Modell (gemeinsam)

- `enum RemotePlaylistSelection { case all; case firstN(Int); case randomN(Int) }`
- Helper `apply(to tracks:) -> [Track]`:
  - `.all` → alle
  - `.firstN(n)` → `Array(prefix(n))`
  - `.randomN(n)` → `Array(shuffled().prefix(n))`
- Anzeige „X Tracks / ~Y Std." vor dem Download (Duration-Summe), damit riesige
  Playlists nicht versehentlich komplett geladen werden.

## Phase C — UI

- **`RemotePlaylistsView`** (aus `SourceCard` → Button „Playlists"): Liste der
  Playlists der Quelle (Cover, Name, Trackzahl, Gesamtdauer). YouTube zusätzlich mit
  URL-Eingabefeld.
- **Playlist-Detail**: Trackliste + Auswahlmodus (Alle / Erste N / Random N mit
  Zahleneingabe) + Button „Herunterladen" → ruft `DownloadViewModel` mit
  `preferredSource` passend zur Quelle.

## Phase D — YouTube

- **`YouTubeClient.listPlaylist(url:)`** via `yt-dlp --flat-playlist -J`.
- Download über `preferredSource = .youtube` (direkt yt-dlp per URL).

## Phase E — Spotify

- **`SpotifyClient.fetchPlaylistTracks(playlistId:)`** (`/playlists/{id}/tracks`,
  `fields`+Paging) → Metadaten.
- Download über `preferredSource = .auto` (Fallback-Kette SC/DAB/Squid/YT anhand
  „Artist – Titel"), da Spotify kein Audio liefert. UI kommuniziert das klar.

## Robustheit

- Dedup über bestehende DB-Prüfung + scdl/yt-dlp `--download-archive`.
- Ein fehlgeschlagener Track kippt die Playlist nicht (Batch-Semantik existiert).

## Reihenfolge

1. Phase 0 (Quell-Pinning) → 2. Phase A (SoundCloud) → 3. Phase B/C (Auswahl + UI)
   → 4. Phase D (YouTube) → 5. Phase E (Spotify).
