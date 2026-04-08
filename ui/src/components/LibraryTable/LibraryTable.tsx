import { useState, useRef } from "react";
import {
  useReactTable,
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  type SortingState,
  type ColumnSizingState,
} from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { Track } from "../../types/library";
import { formatDuration, formatDate } from "../../utils/formatter";
import RowContextMenu, { useRowContextMenu } from "./RowContextMenu";
import { TrackSelectionProvider, useTrackSelection } from "../../contexts/TrackSelectionContext";

interface LibraryTableProps {
  tracks: Track[];
  view?: "library" | "remote";
  onOpenMoreInfo?: (track: Track) => void;
  cachedTrackIds?: Set<number>;
}

const columnHelper = createColumnHelper<Track>();

const columns = [
  columnHelper.accessor((row) => row.metadata.title, {
    id: "title",
    header: "Title",
    size: 260,
    minSize: 100,
    maxSize: 500,
    cell: (info) => {
      const cached = (info.table.options.meta as { cachedTrackIds?: Set<number> })?.cachedTrackIds;
      const trackId = info.row.original.id;
      const isCached = cached && trackId ? cached.has(trackId) : false;
      return (
        <div className="text-[13px] font-medium text-ink truncate flex items-center gap-1.5" title={info.getValue() || "Unknown"}>
          {isCached && (
            <span className="shrink-0 w-1.5 h-1.5 rounded-full bg-emerald-500" title="Transcoded & cached" />
          )}
          {info.getValue() || "Unknown"}
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
      <div className="text-[13px] text-ink-muted text-right tabular-nums font-mono">
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
        <div className="text-[11px] text-ink-muted uppercase tracking-wide">
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
        <div className="text-[13px] text-ink-muted text-right tabular-nums font-mono">
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
      if (!dateStr) return <div className="text-[13px] text-ink-muted">—</div>;
      const timestamp = new Date(dateStr).getTime() / 1000;
      return (
        <div className="text-[13px] text-ink-muted tabular-nums">
          {formatDate(timestamp)}
        </div>
      );
    },
  }),
];

function LibraryTableInner({ tracks, view, onOpenMoreInfo, cachedTrackIds }: LibraryTableProps) {
  const [sorting, setSorting] = useState<SortingState>(
    view === "remote" ? [{ id: "date_added", desc: true }] : []
  );
  const [columnSizing, setColumnSizing] = useState<ColumnSizingState>({});
  const [contextMenuTrack, setContextMenuTrack] = useState<Track | null>(null);
  const [confirmedTracks, setConfirmedTracks] = useState<Set<number>>(new Set());
  const tableContainerRef = useRef<HTMLDivElement>(null);
  const { displayMenu } = useRowContextMenu();
  const { selectedTracks, setSelectedTracks, isSelected } = useTrackSelection();

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
    state: { sorting, columnSizing },
    onSortingChange: setSorting,
    onColumnSizingChange: setColumnSizing,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    columnResizeMode: "onChange",
    enableColumnResizing: true,
    meta: { cachedTrackIds },
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
        className="overflow-auto h-full border border-edge rounded-lg bg-surface select-none"
      >
        <table className="w-full border-collapse table-fixed">
          <thead className="bg-surface sticky top-0 z-10">
            {table.getHeaderGroups().map((headerGroup) => (
              <tr key={headerGroup.id} className="border-b border-edge">
                {headerGroup.headers.map((header) => (
                  <th
                    key={header.id}
                    style={{ width: header.getSize() }}
                    className="relative px-3 py-2 text-left text-[10px] font-semibold text-ink-muted uppercase tracking-wider select-none"
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
                  className={`border-t border-edge-subtle cursor-pointer transition-colors duration-150 ${
                    confirmed
                      ? "bg-emerald-500/10"
                      : selected
                        ? "bg-accent/10"
                        : "hover:bg-raised/60"
                  }`}
                  onClick={(e) => handleRowClick(track, e)}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    setContextMenuTrack(track);
                    displayMenu(e, track);
                  }}
                >
                  {row.getVisibleCells().map((cell) => (
                    <td key={cell.id} className="px-3 py-1.5 overflow-hidden">
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

export default function LibraryTable({ tracks, view, onOpenMoreInfo, cachedTrackIds }: LibraryTableProps) {
  return (
    <TrackSelectionProvider>
      <LibraryTableInner tracks={tracks} view={view} onOpenMoreInfo={onOpenMoreInfo} cachedTrackIds={cachedTrackIds} />
    </TrackSelectionProvider>
  );
}
