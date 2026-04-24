import { useParams, useNavigate } from "react-router";
import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { getAlbumDetail } from "../utils/tauri-commands";
import type { AlbumDetail } from "../types/library";
import { AlbumHero } from "../components/AlbumDetail/AlbumHero";
import { AlbumTracklist } from "../components/AlbumDetail/AlbumTracklist";
import { UfoToggle } from "../components/AlbumDetail/UfoToggle";

/**
 * Route container for `/albums/:slug`.
 *
 * Five states (UI-SPEC §State Matrix):
 *   - Loading: `"Loading album…"`
 *   - Loaded (Yeat + 1 sibling): hero + UFO toggle slot + tracklist
 *   - Loaded (non-Yeat OR sibling count != 1): hero + tracklist only
 *     (UFO slot entirely absent — Phase 22 fills it for siblings >= 2)
 *   - Not found: `"Album not found."` + back link
 *   - Error: `"Couldn't load this album. Try again."` + retry button
 *
 * Phase 22 handoff note: the `{showUfo && variant && (...)}` slot is the
 * component-swap point for the Winamp cycler. When `siblings.length >= 2`,
 * Phase 22 adds a parallel branch that renders its cycler in this same
 * `<div className="flex justify-center py-6">` container.
 */
export default function AlbumDetailPage() {
  const { slug } = useParams<{ slug: string }>();
  const navigate = useNavigate();

  const [detail, setDetail] = useState<AlbumDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedAlbumId, setSelectedAlbumId] = useState<number | null>(null);

  const load = useCallback(async () => {
    if (!slug) return;
    setLoading(true);
    setError(null);
    setNotFound(false);
    try {
      const result = await getAlbumDetail(slug);
      setDetail(result);
      setSelectedAlbumId(result.selected_album_id);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      // Backend returns a stringified Error; "not found" surfaces the 404 state.
      if (msg.toLowerCase().includes("not found")) {
        setNotFound(true);
      } else {
        setError(msg);
        toast.error("Couldn't load this album. Try again.");
      }
    } finally {
      setLoading(false);
    }
  }, [slug]);

  useEffect(() => {
    load();
  }, [load]);

  const onBack = () => {
    // Fall back to `/` if there's no history to pop.
    if (window.history.length > 1) navigate(-1);
    else navigate("/");
  };

  if (loading) {
    return (
      <div className="p-6">
        <p className="text-ink-muted">Loading album…</p>
      </div>
    );
  }
  if (notFound) {
    return (
      <div className="p-6">
        <p className="text-ink-muted mb-2">Album not found.</p>
        <button
          type="button"
          onClick={() => navigate("/")}
          className="text-[13px] text-accent hover:text-accent-bright underline"
        >
          Back to Library
        </button>
      </div>
    );
  }
  if (error || !detail) {
    return (
      <div className="p-6">
        <p className="text-ink-muted mb-2">Couldn't load this album. Try again.</p>
        <button
          type="button"
          onClick={load}
          className="text-[13px] text-accent hover:text-accent-bright underline"
        >
          Retry
        </button>
      </div>
    );
  }

  // Resolve which album's tracks to show based on current selection.
  // selected_album_id is always either album.id (base) or one of the sibling
  // album ids (backend-validated).
  const selected =
    selectedAlbumId === detail.album.id
      ? { album: detail.album, tracks: detail.tracks }
      : detail.siblings.find((s) => s.album.id === selectedAlbumId) ?? {
          album: detail.album,
          tracks: detail.tracks,
        };

  const totalDuration = selected.tracks.reduce(
    (sum, t) => sum + (t.metadata.duration ?? 0),
    0,
  );

  // Toggle renders only for Yeat albums with exactly 1 sibling (base + 1 variant).
  // siblings >= 2 is reserved for Phase 22's Winamp cycler (same slot).
  const showUfo = detail.is_yeat && detail.siblings.length === 1;
  const variant = detail.siblings[0];

  return (
    <div className="flex flex-col h-full overflow-auto">
      <AlbumHero
        album={selected.album}
        trackCount={selected.tracks.length}
        totalDurationSec={totalDuration}
        onBack={onBack}
      />

      {showUfo && variant && (
        <div className="flex justify-center py-6">
          <UfoToggle
            baseAlbumId={detail.album.id}
            variantAlbumId={variant.album.id}
            variantKind={variant.album.variant_kind}
            selectedAlbumId={selectedAlbumId ?? detail.album.id}
            onSelect={(newSelectedId) => {
              setSelectedAlbumId(newSelectedId);
            }}
          />
        </div>
      )}

      <div className="px-5 pb-6 pt-8">
        {/* Key-remount drives the crossfade when the UFO toggle swaps selection. */}
        <AlbumTracklist
          key={selectedAlbumId ?? detail.album.id}
          tracks={selected.tracks}
        />
      </div>
    </div>
  );
}
