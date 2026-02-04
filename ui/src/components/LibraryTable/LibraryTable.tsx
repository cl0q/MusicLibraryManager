import { useState, useRef } from "react";
import {
  useReactTable,
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  type SortingState,
} from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { Track } from "../../types/library";
import { formatDuration, formatDate, formatQuality } from "../../utils/formatter";

interface LibraryTableProps {
  tracks: Track[];
}

const columnHelper = createColumnHelper<Track>();

const columns = [
  columnHelper.accessor("title", {
    header: "Title",
    cell: (info) => (
      <div className="font-medium text-gray-900 dark:text-white truncate">
        {info.getValue()}
      </div>
    ),
  }),
  columnHelper.accessor("artist", {
    header: "Artist",
    cell: (info) => (
      <div className="text-gray-700 dark:text-gray-300 truncate">
        {info.getValue()}
      </div>
    ),
  }),
  columnHelper.accessor("album", {
    header: "Album",
    cell: (info) => (
      <div className="text-gray-700 dark:text-gray-300 truncate">
        {info.getValue()}
      </div>
    ),
  }),
  columnHelper.accessor("duration", {
    header: "Duration",
    cell: (info) => (
      <div className="text-gray-600 dark:text-gray-400 text-right tabular-nums">
        {formatDuration(info.getValue())}
      </div>
    ),
  }),
  columnHelper.accessor("source", {
    header: "Source",
    cell: (info) => {
      const source = info.getValue();
      const colorClass =
        source === "spotify"
          ? "text-green-600 dark:text-green-400"
          : source === "soundcloud"
            ? "text-orange-600 dark:text-orange-400"
            : "text-gray-600 dark:text-gray-400";
      return (
        <div className={`${colorClass} capitalize`}>
          {source}
        </div>
      );
    },
  }),
  columnHelper.accessor("quality", {
    header: "Quality",
    cell: (info) => (
      <div className="text-gray-600 dark:text-gray-400 text-sm">
        {formatQuality(info.getValue())}
      </div>
    ),
  }),
  columnHelper.accessor("date_added", {
    header: "Date Added",
    cell: (info) => {
      // date_added is stored as string in ISO format from Rust
      const dateStr = info.getValue();
      // Parse ISO string to timestamp
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
  const tableContainerRef = useRef<HTMLDivElement>(null);

  const table = useReactTable({
    data: tracks,
    columns,
    state: {
      sorting,
    },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
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
    <div
      ref={tableContainerRef}
      className="overflow-auto h-full border border-gray-200 dark:border-gray-700 rounded-lg"
    >
      <table className="w-full border-collapse">
        <thead className="bg-gray-50 dark:bg-gray-800 sticky top-0 z-10">
          {table.getHeaderGroups().map((headerGroup) => (
            <tr key={headerGroup.id}>
              {headerGroup.headers.map((header) => (
                <th
                  key={header.id}
                  className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-700 select-none"
                  onClick={header.column.getToggleSortingHandler()}
                >
                  <div className="flex items-center gap-2">
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
            return (
              <tr
                key={row.id}
                className="border-t border-gray-200 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-800"
              >
                {row.getVisibleCells().map((cell) => (
                  <td key={cell.id} className="px-4 py-2">
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
  );
}
