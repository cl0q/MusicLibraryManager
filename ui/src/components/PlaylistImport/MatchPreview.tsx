import type { ImportPlaylistResult } from '../../utils/tauri-commands';

interface MatchPreviewProps {
  result: ImportPlaylistResult;
}

export function MatchPreview({ result }: MatchPreviewProps) {
  const matchRate = result.total_tracks > 0
    ? Math.round((result.matched_tracks / result.total_tracks) * 100)
    : 0;

  return (
    <div className="flex flex-col gap-3">
      {/* Summary row */}
      <div className="flex items-center gap-4 p-3 bg-raised rounded-lg border border-edge">
        <div className="flex flex-col items-center">
          <span className="text-2xl font-bold text-green-400">{result.matched_tracks}</span>
          <span className="text-xs text-ink-muted">matched</span>
        </div>
        <div className="flex flex-col items-center">
          <span className="text-2xl font-bold text-ink-muted">{result.unmatched_tracks}</span>
          <span className="text-xs text-ink-muted">unmatched</span>
        </div>
        <div className="flex flex-col items-center ml-auto">
          <span className="text-2xl font-bold">{matchRate}%</span>
          <span className="text-xs text-ink-muted">match rate</span>
        </div>
      </div>

      {/* Unmatched tracks list */}
      {result.unmatched_details.length > 0 && (
        <div className="flex flex-col gap-1">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
            Unmatched tracks ({result.unmatched_details.length})
          </p>
          <div className="max-h-40 overflow-y-auto flex flex-col gap-0.5">
            {result.unmatched_details.map((track, i) => (
              <div
                key={i}
                className="flex items-center gap-2 px-2 py-1 rounded text-[13px] text-ink-muted"
              >
                <span className="text-orange-400 text-xs shrink-0">No match</span>
                <span className="truncate">{track}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
