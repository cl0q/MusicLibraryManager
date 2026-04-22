import { useState, useEffect } from 'react';
import { useReviewQueue } from '../../hooks/useEnhancements';

/**
 * Review queue — Solar restyle. The Solar mock (ReviewScreen) depicts a
 * source→candidate pattern with confidence bars that our current backend
 * does not emit; this restyle keeps the existing list/action semantics but
 * reskins every surface to Solar tokens (bg-surface, border-edge, tabular
 * monospace for IDs/percentages, accent-coloured Approve buttons, etc.).
 *
 * When the backend starts emitting `similarity_score` in review items, the
 * ConfidenceBar atom below is already wired for it.
 */

type FilterStatus = 'all' | 'pending' | 'approved' | 'rejected' | 'dismissed';

export default function ReviewQueue() {
  const { items, loading, error, refresh, resolve } = useReviewQueue();
  const [filter, setFilter] = useState<FilterStatus>('all');
  const [resolving, setResolving] = useState<number | null>(null);

  useEffect(() => {
    const statusFilter = filter === 'all' ? undefined : filter;
    refresh(statusFilter);
  }, [filter, refresh]);

  const handleResolve = async (id: number, action: string) => {
    setResolving(id);
    try {
      await resolve(id, action);
    } catch (err) {
      console.error('Failed to resolve:', err);
    } finally {
      setResolving(null);
    }
  };

  const handleBulkAction = async (action: 'approved' | 'dismissed') => {
    const pendingItems = items.filter(item => item.status === 'pending');
    for (const item of pendingItems) {
      try {
        await resolve(item.id, action);
      } catch (err) {
        console.error(`Failed to ${action} item ${item.id}:`, err);
      }
    }
  };

  const parseDetails = (detailsJson: string): Record<string, unknown> => {
    try {
      return JSON.parse(detailsJson);
    } catch {
      return {};
    }
  };

  const filteredItems = items.filter(item => filter === 'all' || item.status === filter);
  const pendingCount = items.filter((i) => i.status === 'pending').length;

  return (
    <div className="flex flex-col gap-3" style={{ fontFamily: 'var(--font-ui)' }}>
      {/* Header row — mirrors the ReviewScreen layout */}
      <div className="flex items-center gap-3">
        <span className="text-[13px] font-semibold text-ink">Review queue</span>
        <span className="text-[11px] text-ink-muted">
          {pendingCount} pending · {items.length} total
        </span>
        <div className="flex-1" />
        <span className="text-[10px] text-ink-muted">
          <Kbd>A</Kbd> accept <Kbd>S</Kbd> skip
        </span>
        <button
          onClick={() => handleBulkAction('approved')}
          disabled={loading || pendingCount === 0}
          className="h-7 px-2.5 rounded-[5px] bg-accent text-[11px] font-medium hover:bg-accent-bright transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          style={{ color: 'var(--color-base)' }}
        >
          Approve all
        </button>
        <button
          onClick={() => handleBulkAction('dismissed')}
          disabled={loading || pendingCount === 0}
          className="h-7 px-2.5 rounded-[5px] bg-raised border border-edge text-[11px] font-medium text-ink-secondary hover:text-ink transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
        >
          Dismiss all
        </button>
      </div>

      {/* Filter tabs */}
      <div className="flex gap-0.5 bg-raised rounded-[5px] p-0.5 self-start">
        {(['all', 'pending', 'approved', 'rejected', 'dismissed'] as FilterStatus[]).map((status) => {
          const active = filter === status;
          return (
            <button
              key={status}
              onClick={() => setFilter(status)}
              className={`px-3 py-[5px] text-[11px] font-medium rounded-[3px] capitalize transition-colors ${
                active ? 'bg-overlay text-ink' : 'text-ink-muted hover:text-ink'
              }`}
            >
              {status}
            </button>
          );
        })}
      </div>

      {error && (
        <div className="bg-rose-500/10 border border-rose-500/20 rounded px-3 py-2 text-[12px] text-rose-400">
          {error}
        </div>
      )}

      {loading ? (
        <div className="flex items-center justify-center py-10">
          <span className="w-5 h-5 rounded-full border border-ink-muted border-t-sky-400 animate-spin" />
        </div>
      ) : filteredItems.length === 0 ? (
        <div className="text-center py-10">
          <p className="text-[12px] text-ink-muted">No items in review queue</p>
          <p className="text-[11px] text-ink-muted mt-1">
            Items appear here when automated actions need human review.
          </p>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          {filteredItems.map((item) => {
            const details = parseDetails(item.details);
            const similarity =
              typeof details.similarity_score === 'number' ? details.similarity_score * 100 : null;
            const qualityInfo =
              typeof details.quality_info === 'string' ? details.quality_info : null;
            return (
              <div
                key={item.id}
                className="border border-edge rounded-md bg-surface overflow-hidden"
              >
                {/* Source row */}
                <div className="flex items-center gap-3 px-3.5 py-2 bg-raised border-b border-edge">
                  <span className="inline-flex items-center justify-center w-[18px] h-[18px] rounded text-[10px] font-bold uppercase tracking-wide"
                    style={{
                      background: 'color-mix(in oklab, var(--color-accent) 16%, transparent)',
                      color: 'var(--color-accent)',
                    }}
                  >
                    {item.action_type.slice(0, 1).toUpperCase()}
                  </span>
                  <div className="flex-1 min-w-0">
                    <div className="text-[11px] text-ink-muted">
                      <span
                        className="text-[10px] uppercase tracking-[0.08em] font-semibold mr-2"
                        style={{ color: 'var(--color-accent)' }}
                      >
                        {item.action_type.replace(/_/g, ' ')}
                      </span>
                      Track #{item.track_id}
                      {item.related_track_id !== null && ` ↔ #${item.related_track_id}`}
                    </div>
                    <div className="text-[12px] text-ink">
                      {qualityInfo || 'Awaiting review'}
                    </div>
                  </div>
                  <span
                    className={`text-[10px] px-2 py-0.5 rounded-full font-medium uppercase tracking-[0.06em] ${
                      item.status === 'pending'
                        ? 'bg-amber-500/15 text-amber-400'
                        : item.status === 'approved'
                          ? 'bg-emerald-500/15 text-emerald-400'
                          : item.status === 'rejected'
                            ? 'bg-rose-500/15 text-rose-400'
                            : 'bg-raised text-ink-muted'
                    }`}
                  >
                    {item.status}
                  </span>
                  <span className="text-[10px] text-ink-muted tabular-nums" style={{ fontFamily: 'var(--font-mono)' }}>
                    {new Date(item.created_at).toLocaleDateString()}
                  </span>
                </div>

                {/* Details row with confidence + actions */}
                <div className="grid grid-cols-[80px_1fr_auto] items-center gap-3 px-3.5 py-2.5">
                  <ConfidenceBar value={similarity} />
                  <div className="min-w-0">
                    <div className="text-[12.5px] text-ink truncate">
                      {item.auto_action ? `Suggestion: ${item.auto_action}` : 'No suggestion'}
                    </div>
                    <div className="text-[10.5px] text-ink-muted mt-0.5 truncate" style={{ fontFamily: 'var(--font-mono)' }}>
                      item #{item.id}
                      {similarity !== null ? ` · ${similarity.toFixed(1)}% similar` : ''}
                    </div>
                  </div>
                  {item.status === 'pending' ? (
                    <div className="flex gap-1">
                      <button
                        onClick={() => handleResolve(item.id, 'approved')}
                        disabled={resolving === item.id}
                        className="h-[26px] px-3 rounded-[4px] bg-accent text-[11px] font-semibold hover:bg-accent-bright transition-colors disabled:opacity-50"
                        style={{ color: 'var(--color-base)' }}
                      >
                        Accept
                      </button>
                      <button
                        onClick={() => handleResolve(item.id, 'rejected')}
                        disabled={resolving === item.id}
                        className="h-[26px] px-3 rounded-[4px] bg-raised border border-edge text-[11px] text-ink-secondary hover:text-ink transition-colors disabled:opacity-50"
                      >
                        Reject
                      </button>
                      <button
                        onClick={() => handleResolve(item.id, 'dismissed')}
                        disabled={resolving === item.id}
                        className="h-[26px] px-3 rounded-[4px] bg-raised border border-edge text-[11px] text-ink-muted hover:text-ink transition-colors disabled:opacity-50"
                      >
                        Skip
                      </button>
                    </div>
                  ) : (
                    <span className="text-[11px] text-ink-muted">{item.resolved_at ? `resolved ${new Date(item.resolved_at).toLocaleDateString()}` : ''}</span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

/**
 * Two-line confidence indicator from ReviewRow mock. Color reflects
 * accept-threshold: green >80, accent 60–80, rose <60. Renders a muted
 * placeholder when similarity isn't available.
 */
function ConfidenceBar({ value }: { value: number | null }) {
  if (value === null) {
    return (
      <div className="text-[10px] text-ink-muted" style={{ fontFamily: 'var(--font-mono)' }}>
        —
      </div>
    );
  }
  const color = value > 80 ? 'var(--color-emerald, #34d399)' : value > 60 ? 'var(--color-accent)' : '#fb7185';
  return (
    <div>
      <div
        className="text-[10px] font-bold mb-[3px] tabular-nums"
        style={{ color, fontFamily: 'var(--font-mono)' }}
      >
        {value.toFixed(0)}%
      </div>
      <div className="h-[3px] bg-edge rounded-[2px] overflow-hidden">
        <div style={{ width: `${value}%`, height: '100%', background: color }} />
      </div>
    </div>
  );
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <span
      className="inline-flex items-center justify-center min-w-4 h-4 px-1 rounded-[3px] border border-edge bg-raised text-ink-muted mx-0.5"
      style={{ fontFamily: 'var(--font-mono)', fontSize: 10 }}
    >
      {children}
    </span>
  );
}
