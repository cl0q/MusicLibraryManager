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

interface LibraryTableProps {
  tracks: Track[];
}

const columnHelper = createColumnHelper<Track>();

const columns = [
  columnHelper.accessor((row) => row.metadata.title, {
    id: "title",
    header: "Title",
    size: 250,
    minSize: 100,
    maxSize: 500,
    cell: (info) => (
      <div className="font-medium text-gray-900 dark:text-white truncate" title={info.getValue() || "Unknown"}>
        {info.getValue() || "Unknown"}
      </div>
    ),
  }),
  columnHelper.accessor((row) => row.metadata.artist, {
    id: "artist",
    header: "Artist",
    size: 180,
    minSize: 80,
    maxSize: 400,
    cell: (info) => (
      <div className="text-gray-700 dark:text-gray-300 truncate" title={info.getValue() || "Unknown"}>
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
      <div className="text-gray-700 dark:text-gray-300 truncate" title={info.getValue() || "Unknown"}>
        {info.getValue() || "Unknown"}
      </div>
    ),
  }),
  columnHelper.accessor((row) => row.metadata.duration, {
    id: "duration",
    header: "Duration",
    size: 80,
    minSize: 60,
    maxSize: 120,
    cell: (info) => (
      <div className="text-gray-600 dark:text-gray-400 text-right tabular-nums">
        {formatDuration(info.getValue() ?? 0)}
      </div>
    ),
  }),
  columnHelper.accessor((row) => row.metadata.format, {
    id: "format",
    header: "Format",
    size: 80,
    minSize: 60,
    maxSize: 120,
    cell: (info) => {
      const format = info.getValue();
      const displayFormat =
        format === "spotify" || format === "soundcloud"
          ? "Stream"
          : (format || "Unknown").toUpperCase();
      return (
        <div className="text-gray-600 dark:text-gray-400 text-sm">
          {displayFormat}
        </div>
      );
    },
  }),
  columnHelper.accessor((row) => row.metadata.bitrate, {
    id: "bitrate",
    header: "Bitrate",
    size: 90,
    minSize: 60,
    maxSize: 120,
    cell: (info) => {
      const bitrate = info.getValue();
      return (
        <div className="text-gray-600 dark:text-gray-400 text-sm">
          {bitrate ? `${bitrate} kbps` : "-"}
        </div>
      );
    },
  }),
  columnHelper.accessor("date_added", {
    header: "Date Added",
    size: 110,
    minSize: 80,
    maxSize: 150,
    cell: (info) => {
      const dateStr = info.getValue();
      if (!dateStr) return <div className="text-gray-600 dark:text-gray-400 text-sm">-</div>;
      const timestamp = new Date(dateStr).getTime() / 1000;
      return (
        <div className="text-gray-600 dark:text-gray-400 text-sm">
          {formatDate(timestamp)}
        </div>
      );
    },
  }),
];

export default function LibraryTable({ tracks }: LibraryTableProps) {
  const [sorting, setSorting] = useState<SortingState>([]);
  const [columnSizing, setColumnSizing] = useState<ColumnSizingState>({});
  const [contextMenuTrack, setContextMenuTrack] = useState<Track | null>(null);
  const tableContainerRef = useRef<HTMLDivElement>(null);
  const { displayMenu } = useRowContextMenu();

  const table = useReactTable({
    data: tracks,
    columns,
    state: {
      sorting,
      columnSizing,
    },
    onSortingChange: setSorting,
    onColumnSizingChange: setColumnSizing,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    columnResizeMode: "onChange",
    enableColumnResizing: true,
  });

  const { rows } = table.getRowModel();

  const rowVirtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => tableContainerRef.current,
    estimateSize: () => 40,
    overscan: 5,
  });

  const virtualRows = rowVirtualizer.getVirtualItems();
  const totalSize = rowVirtualizer.getTotalSize();

  const paddingTop = virtualRows.length > 0 ? virtualRows[0]?.start || 0 : 0;
  const paddingBottom =
    virtualRows.length > 0
      ? totalSize - (virtualRows[virtualRows.length - 1]?.end || 0)
      : 0;

  return (
    <>
      <div
        ref={tableContainerRef}
        className="overflow-auto h-full border border-gray-200 dark:border-gray-700 rounded-lg"
      >
        <table className="w-full border-collapse table-fixed">
          <thead className="bg-gray-50 dark:bg-gray-800 sticky top-0 z-10">
            {table.getHeaderGroups().map((headerGroup) => (
              <tr key={headerGroup.id}>
                {headerGroup.headers.map((header) => (
                  <th
                    key={header.id}
                    style={{ width: header.getSize() }}
                    className="relative px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider select-none group"
                  >
                    <div
                      className="flex items-center gap-2 cursor-pointer hover:text-gray-700 dark:hover:text-gray-200"
                      onClick={header.column.getToggleSortingHandler()}
                    >
                      {flexRender(
                        header.column.columnDef.header,
                        header.getContext()
                      )}
                      {header.column.getIsSorted() && (
                        <span className="text-blue-600 dark:text-blue-400">
                          {header.column.getIsSorted() === "asc" ? "↑" : "↓"}
                        </span>
                      )}
                    </div>
                    {/* Resize handle */}
                    {header.column.getCanResize() && (
                      <div
                        onMouseDown={header.getResizeHandler()}
                        onTouchStart={header.getResizeHandler()}
                        className={`absolute right-0 top-0 h-full w-1 cursor-col-resize select-none touch-none
                          ${header.column.getIsResizing()
                            ? "bg-blue-500"
                            : "bg-transparent hover:bg-gray-300 dark:hover:bg-gray-600"
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
              <tr>
                <td style={{ height: `${paddingTop}px` }} />
              </tr>
            )}
            {virtualRows.map((virtualRow) => {
              const row = rows[virtualRow.index];
              const track = row.original;
              return (
                <tr
                  key={row.id}
                  className="border-t border-gray-200 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer"
                  onContextMenu={(e) => {
                    e.preventDefault();
                    setContextMenuTrack(track);
                    displayMenu(e, track);
                  }}
                >
                  {row.getVisibleCells().map((cell) => (
                    <td key={cell.id} className="px-4 py-2 overflow-hidden">
                      {flexRender(cell.column.columnDef.cell, cell.getContext())}
                    </td>
                  ))}
                </tr>
              );
            })}
            {paddingBottom > 0 && (
              <tr>
                <td style={{ height: `${paddingBottom}px` }} />
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <RowContextMenu track={contextMenuTrack} />
    </>
  );
}
