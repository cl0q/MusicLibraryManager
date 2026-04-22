import { useState, useRef, useEffect } from "react";
import {
  useReactTable,
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  type SortingState,
  type ColumnSizingState,
  type VisibilityState,
} from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { Track } from "../../types/library";
import { formatDuration, formatDate } from "../../utils/formatter";
import RowContextMenu, { useRowContextMenu } from "./RowContextMenu";
import { TrackSelectionProvider, useTrackSelection } from "../../contexts/TrackSelectionContext";
import EnergyBars from "./EnergyBars";

interface LibraryTableProps {
  tracks: Track[];
  view?: "library" | "remote";
  onOpenMoreInfo?: (track: Track) => void;
  cachedTrackIds?: Set<number>;
  /** Column visibility override — used by MoreInfo/Settings to toggle the `energy` column on. */
  columnVisibility?: VisibilityState;
  onColumnVisibilityChange?: (v: VisibilityState) => void;
}

/**
 * SourceBadge — tiny pill indicating where a track originates (Spotify,
 * SoundCloud, etc.). Rendered inline in the Title cell when the track has
 * a streaming origin.
 */
function SourceBadge({ source }: { source: string | null | undefined }) {
  if (!source) return null;
  const map: Record<string, { color: string; label: string }> = {
    spotify: { color: "var(--color-emerald, #10b981)", label: "Spotify" },
    soundcloud: { color: "#ff7a00", label: "SoundCloud" },
    bandcamp: { color: "#1da0c3", label: "Bandcamp" },
    beatport: { color: "var(--color-sky, #38bdf8)", label: "Beatport" },
  };
  const key = source.toLowerCase();
  const entry = map[key];
  if (!entry) return null;
  return (
    <span
      className="shrink-0 inline-flex items-center px-1 py-px rounded text-[10px] leading-none uppercase tracking-wide"
      style={{
        color: entry.color,
        background: `color-mix(in oklab, ${entry.color} 14%, transparent)`,
      }}
    >
      {entry.label}
    </span>
  );
}

const columnHelper = createColumnHelper<Track>();

const columns = [
  columnHelper.accessor((row) => row.metadata.title, {
    id: "title",
    header: "Title",
    size: 260,
    minSize: 120,
    maxSize: 500,
    cell: (info) => {
      const meta = info.table.options.meta as {
        cachedTrackIds?: Set<number>;
        view?: "library" | "remote";
      };
      const cached = meta?.cachedTrackIds;
      const view = meta?.view;
      const track = info.row.original;
      const trackId = track.id;
      const isCached = cached && trackId ? cached.has(trackId) : false;
      const isRemoteView = view === "remote";

      return (
        <div className="text-[13px] text-ink truncate flex items-center gap-1.5" title={info.getValue() || "Unknown"}>
          {isCached ? (
            <span
              className="shrink-0 w-[5px] h-[5px] rounded-full bg-emerald-500"
              title="Cached locally"
            />
          ) : isRemoteView ? (
            <span
              className="shrink-0 w-[5px] h-[5px] rounded-full bg-ink-muted"
              title="Remote — not downloaded"
            />
          ) : null}
          <span className="truncate font-medium">{info.getValue() || "Unknown"}</span>
          <SourceBadge source={track.metadata.format} />
        </div>
      );
    },
  }),
  columnHelper.accessor((row) => row.metadata.artist, {
    id: "artist",
    header: "Artist",
    size: 180,
    minSize: 80,
    maxSize: 400,
    cell: (info) => (
      <div className="text-[13px] text-ink-secondary truncate" title={info.getValue() || "Unknown"}>
        {info.getValue() || "Unknown"}
      </div>
    ),
  }),
  columnHelper.accessor((row) => row.metadata.album, {
    id: "album",
    header: "Album",
    size: 180,
    minSize: 80,
    maxSize: 400,
    cell: (info) => (
      <div className="text-[13px] text-ink-secondary truncate" title={info.getValue() || "Unknown"}>
        {info.getValue() || "Unknown"}
      </div>
    ),
  }),
  columnHelper.accessor((row) => row.metadata.duration, {
    id: "duration",
    header: "Time",
    size: 65,
    minSize: 50,
    maxSize: 100,
    cell: (info) => (
      <div
        className="text-[12px] text-ink-muted text-right tabular-nums"
        style={{ fontFamily: "var(--font-mono)" }}
      >
        {formatDuration(info.getValue() ?? 0)}
      </div>
    ),
  }),
  columnHelper.accessor((row) => row.metadata.format, {
    id: "format",
    header: "Fmt",
    size: 60,
    minSize: 45,
    maxSize: 100,
    cell: (info) => {
      const format = info.getValue();
      const display =
        format === "spotify" || format === "soundcloud"
          ? "Stream"
          : (format || "—").toUpperCase();
      return (
        <div
          className="text-[10px] text-ink-muted uppercase tracking-[0.06em]"
          style={{ fontFamily: "var(--font-mono)" }}
        >
          {display}
        </div>
      );
    },
  }),
  columnHelper.accessor((row) => row.metadata.bitrate, {
    id: "bitrate",
    header: "Kbps",
    size: 65,
    minSize: 50,
    maxSize: 100,
    cell: (info) => {
      const bitrate = info.getValue();
      const display = bitrate ? (bitrate > 10000 ? Math.round(bitrate / 1000) : bitrate) : null;
      return (
        <div
          className="text-[12px] text-ink-muted text-right tabular-nums"
          style={{ fontFamily: "var(--font-mono)" }}
        >
          {display ?? "—"}
        </div>
      );
    },
  }),
  columnHelper.accessor("date_added", {
    header: "Added",
    size: 90,
    minSize: 70,
    maxSize: 150,
    cell: (info) => {
      const dateStr = info.getValue();
      if (!dateStr) return <div className="text-[12px] text-ink-muted">—</div>;
      const timestamp = new Date(dateStr).getTime() / 1000;
      return (
        <div
          className="text-[12px] text-ink-muted tabular-nums"
          style={{ fontFamily: "var(--font-mono)" }}
        >
          {formatDate(timestamp)}
        </div>
      );
    },
  }),
  // Hidden by default — users opt in via the column-menu toggle.
  // Populated by the Phase 18 loudness analysis pipeline (nullable INTEGER).
  columnHelper.accessor((row) => row.energy_bucket ?? null, {
    id: "energy",
    header: "Energy",
    size: 70,
    minSize: 50,
    maxSize: 120,
    cell: (info) => <EnergyBars value={info.getValue() as number | null} />,
  }),
];

function LibraryTableInner({
  tracks,
  view,
  onOpenMoreInfo,
  cachedTrackIds,
  columnVisibility,
  onColumnVisibilityChange,
}: LibraryTableProps) {
  const [sorting, setSorting] = useState<SortingState>(
    view === "remote" ? [{ id: "date_added", desc: true }] : []
  );
  const [columnSizing, setColumnSizing] = useState<ColumnSizingState>({});
  // Internal visibility fallback when parent doesn't manage it. `energy` is
  // hidden by default — Phase 18 surfaces the toggle in the column menu.
  const [internalVisibility, setInternalVisibility] = useState<VisibilityState>({ energy: false });
  const resolvedVisibility = columnVisibility ?? internalVisibility;
  const handleVisibilityChange: React.Dispatch<React.SetStateAction<VisibilityState>> = (updater) => {
    if (onColumnVisibilityChange) {
      const next =
        typeof updater === "function"
          ? (updater as (old: VisibilityState) => VisibilityState)(resolvedVisibility)
          : updater;
      onColumnVisibilityChange(next);
    } else {
      setInternalVisibility(updater);
    }
  };

  const [contextMenuTrack, setContextMenuTrack] = useState<Track | null>(null);
  const [confirmedTracks, setConfirmedTracks] = useState<Set<number>>(new Set());
  const tableContainerRef = useRef<HTMLDivElement>(null);
  const { displayMenu } = useRowContextMenu();
  const { selectedTracks, setSelectedTracks, isSelected, clearSelection } = useTrackSelection();

  // Esc clears selection (needed by batch bar in Phase 19 too)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && selectedTracks.length > 0) {
        clearSelection();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [selectedTracks.length, clearSelection]);

  const showInlineConfirmation = (trackIds: number[]) => {
    setConfirmedTracks((prev) => {
      const updated = new Set(prev);
      trackIds.forEach((id) => updated.add(id));
      return updated;
    });
    setTimeout(() => {
      setConfirmedTracks((prev) => {
        const updated = new Set(prev);
        trackIds.forEach((id) => updated.delete(id));
        return updated;
      });
    }, 2000);
  };

  const handleRowClick = (track: Track, event: React.MouseEvent) => {
    if (event.target instanceof HTMLElement) {
      const target = event.target as HTMLElement;
      if (target.closest("th") || target.closest(".cursor-col-resize")) return;
    }

    if (event.metaKey || event.ctrlKey) {
      if (isSelected(track.id)) {
        setSelectedTracks(selectedTracks.filter((t) => t.id !== track.id));
      } else {
        setSelectedTracks([...selectedTracks, track]);
      }
    } else if (event.shiftKey && selectedTracks.length > 0) {
      const lastSelected = selectedTracks[selectedTracks.length - 1];
      const lastIndex = tracks.findIndex((t) => t.id === lastSelected.id);
      const currentIndex = tracks.findIndex((t) => t.id === track.id);
      if (lastIndex !== -1 && currentIndex !== -1) {
        const start = Math.min(lastIndex, currentIndex);
        const end = Math.max(lastIndex, currentIndex);
        setSelectedTracks(tracks.slice(start, end + 1));
      }
    } else {
      setSelectedTracks([track]);
    }
  };

  const table = useReactTable({
    data: tracks,
    columns,
    state: { sorting, columnSizing, columnVisibility: resolvedVisibility },
    onSortingChange: setSorting,
    onColumnSizingChange: setColumnSizing,
    onColumnVisibilityChange: handleVisibilityChange,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    columnResizeMode: "onChange",
    enableColumnResizing: true,
    meta: { cachedTrackIds, view },
  });

  const { rows } = table.getRowModel();

  const rowVirtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => tableContainerRef.current,
    estimateSize: () => 36,
    overscan: 5,
  });

  const virtualRows = rowVirtualizer.getVirtualItems();
  const totalSize = rowVirtualizer.getTotalSize();
  const paddingTop = virtualRows.length > 0 ? virtualRows[0]?.start || 0 : 0;
  const paddingBottom = virtualRows.length > 0
    ? totalSize - (virtualRows[virtualRows.length - 1]?.end || 0)
    : 0;

  return (
    <>
      <div
        ref={tableContainerRef}
        className="overflow-auto h-full border border-edge rounded-md bg-surface select-none"
        style={{ fontFamily: "var(--font-ui)" }}
      >
        <table className="w-full border-collapse table-fixed">
          <thead className="bg-surface sticky top-0 z-10">
            {table.getHeaderGroups().map((headerGroup) => (
              <tr key={headerGroup.id} className="border-b border-edge">
                {headerGroup.headers.map((header) => (
                  <th
                    key={header.id}
                    style={{ width: header.getSize() }}
                    className="relative px-3 py-2 text-left text-[10px] font-semibold text-ink-muted uppercase tracking-[0.08em] select-none"
                  >
                    <div
                      className="flex items-center gap-1.5 cursor-pointer hover:text-ink-secondary transition-colors"
                      onClick={header.column.getToggleSortingHandler()}
                    >
                      {flexRender(header.column.columnDef.header, header.getContext())}
                      {header.column.getIsSorted() && (
                        <span className="text-accent text-[10px]">
                          {header.column.getIsSorted() === "asc" ? "↑" : "↓"}
                        </span>
                      )}
                    </div>
                    {header.column.getCanResize() && (
                      <div
                        onMouseDown={header.getResizeHandler()}
                        onTouchStart={header.getResizeHandler()}
                        className={`absolute right-0 top-0 h-full w-1 cursor-col-resize select-none touch-none ${
                          header.column.getIsResizing()
                            ? "bg-accent"
                            : "bg-transparent hover:bg-edge"
                        }`}
                      />
                    )}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody>
            {paddingTop > 0 && (
              <tr><td style={{ height: `${paddingTop}px` }} /></tr>
            )}
            {virtualRows.map((virtualRow) => {
              const row = rows[virtualRow.index];
              const track = row.original;
              const selected = isSelected(track.id);
              const confirmed = track.id !== null && confirmedTracks.has(track.id);

              return (
                <tr
                  key={row.id}
                  className={`border-t border-edge-subtle cursor-pointer transition-colors duration-100 ${
                    confirmed
                      ? "bg-emerald-500/10"
                      : selected
                        ? "bg-accent/10"
                        : "hover:bg-raised/60"
                  }`}
                  style={{ height: "var(--row-h, 36px)" }}
                  onClick={(e) => handleRowClick(track, e)}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    setContextMenuTrack(track);
                    displayMenu(e, track);
                  }}
                >
                  {row.getVisibleCells().map((cell) => (
                    <td
                      key={cell.id}
                      className="overflow-hidden align-middle px-3"
                      style={{ paddingTop: "var(--row-py, 6px)", paddingBottom: "var(--row-py, 6px)" }}
                    >
                      {flexRender(cell.column.columnDef.cell, cell.getContext())}
                    </td>
                  ))}
                </tr>
              );
            })}
            {paddingBottom > 0 && (
              <tr><td style={{ height: `${paddingBottom}px` }} /></tr>
            )}
          </tbody>
        </table>
      </div>
      <RowContextMenu track={contextMenuTrack} onConfirm={showInlineConfirmation} onOpenMoreInfo={onOpenMoreInfo} />
    </>
  );
}

export default function LibraryTable(props: LibraryTableProps) {
  return (
    <TrackSelectionProvider>
      <LibraryTableInner {...props} />
    </TrackSelectionProvider>
  );
}
