import { useState } from 'react';
import { open } from '@tauri-apps/plugin-dialog';
import { importPlaylistFromFile, type ImportPlaylistResult } from '../../utils/tauri-commands';
import { MatchPreview } from './MatchPreview';

/**
 * Import-playlist modal — Solar mock (screens.jsx::ImportModalScreen).
 *
 * Styling: centered 560px panel, base/surface layered background, heavy
 * shadow, dimmed backdrop. Uses uppercase section labels with letter
 * spacing, monospace rows for file/track summaries.
 */

interface ImportModalProps {
  onClose: () => void;
  onPlaylistCreated: () => void;
}

type Step = 'select' | 'preview';

export function ImportModal({ onClose, onPlaylistCreated }: ImportModalProps) {
  const [step, setStep] = useState<Step>('select');
  const [filePath, setFilePath] = useState<string | null>(null);
  const [playlistName, setPlaylistName] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<ImportPlaylistResult | null>(null);

  async function handlePickFile() {
    try {
      const selected = await open({
        multiple: false,
        filters: [{ name: 'Playlist files', extensions: ['m3u', 'm3u8', 'json'] }],
      });
      if (typeof selected === 'string') {
        setFilePath(selected);
        setError(null);
        const filename = selected.split('/').pop() ?? selected.split('\\').pop() ?? 'Imported Playlist';
        const nameWithoutExt = filename.replace(/\.(m3u8?|json)$/i, '');
        setPlaylistName(nameWithoutExt);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to open file dialog');
    }
  }

  async function handleImport() {
    if (!filePath || !playlistName.trim()) return;
    setLoading(true);
    setError(null);
    try {
      const importResult = await importPlaylistFromFile(playlistName.trim(), filePath);
      setResult(importResult);
      setStep('preview');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Import failed');
    } finally {
      setLoading(false);
    }
  }

  function handleConfirmCreate() {
    onPlaylistCreated();
    onClose();
  }

  function handleBackdropClick(e: React.MouseEvent<HTMLDivElement>) {
    if (e.target === e.currentTarget) onClose();
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      style={{
        background: 'color-mix(in oklab, var(--color-base) 80%, transparent)',
        backdropFilter: 'blur(2px)',
        fontFamily: 'var(--font-ui)',
      }}
      onClick={handleBackdropClick}
    >
      <div
        className="bg-surface border border-edge rounded-lg w-[560px] max-w-full mx-4 overflow-hidden"
        style={{ boxShadow: '0 20px 80px rgba(0,0,0,0.45), 0 0 0 1px rgba(0,0,0,0.25)' }}
      >
        {/* Header */}
        <div className="flex items-center gap-2.5 px-5 pt-4 pb-3.5 border-b border-edge-subtle">
          <svg className="w-4 h-4 text-ink-secondary" fill="none" stroke="currentColor" strokeWidth={1.7} viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v8m0 0l-3-3m3 3l3-3M4 14v4a2 2 0 002 2h12a2 2 0 002-2v-4" />
          </svg>
          <span className="text-[14px] font-semibold text-ink">Import playlist</span>
          <div className="flex-1" />
          <button
            onClick={onClose}
            className="text-ink-muted hover:text-ink transition-colors"
            aria-label="Close"
          >
            <svg className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth={1.7} viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>

        {/* Body */}
        <div className="p-5">
          {step === 'select' && (
            <div className="flex flex-col gap-4">
              <div>
                <Label>Source</Label>
                <div className="flex items-center gap-2.5 p-2.5 bg-raised border border-edge rounded-[5px]">
                  <div
                    className="w-8 h-8 rounded shrink-0"
                    style={{ background: 'linear-gradient(135deg, var(--color-accent), var(--color-accent-bright))' }}
                  />
                  <div className="flex-1 min-w-0">
                    <div className="text-[13px] text-ink truncate font-medium">
                      {filePath
                        ? (filePath.split('/').pop() ?? filePath.split('\\').pop() ?? filePath)
                        : 'No file selected'}
                    </div>
                    <div className="text-[11px] text-ink-muted truncate">
                      Supported: .m3u, .m3u8, Spotify .json export
                    </div>
                  </div>
                  <button
                    onClick={handlePickFile}
                    className="h-7 px-3 rounded-[5px] bg-raised border border-edge text-[11px] font-medium text-ink-secondary hover:text-ink hover:bg-overlay transition-colors whitespace-nowrap"
                  >
                    Browse
                  </button>
                </div>
              </div>

              <div>
                <Label>Playlist name</Label>
                <input
                  type="text"
                  value={playlistName}
                  onChange={(e) => setPlaylistName(e.target.value)}
                  placeholder="Enter playlist name"
                  className="w-full h-[32px] px-3 text-[13px] bg-raised border border-edge rounded-[5px] text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
                />
              </div>

              {error && <p className="text-[12px] text-rose-400">{error}</p>}
            </div>
          )}

          {step === 'preview' && result && (
            <div className="flex flex-col gap-3">
              <Label>Match preview</Label>
              <MatchPreview result={result} />
              {error && <p className="text-[12px] text-rose-400">{error}</p>}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center gap-2 justify-end px-5 py-3 border-t border-edge-subtle">
          {step === 'select' ? (
            <>
              <button
                onClick={onClose}
                className="h-[30px] px-3.5 rounded-[5px] bg-transparent border border-edge text-[12px] text-ink-secondary hover:text-ink transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleImport}
                disabled={!filePath || !playlistName.trim() || loading}
                className="h-[30px] px-4 rounded-[5px] bg-accent text-[12px] font-semibold hover:bg-accent-bright disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
                style={{ color: 'var(--color-base)' }}
              >
                {loading ? 'Matching…' : 'Preview matches'}
              </button>
            </>
          ) : (
            <>
              <button
                onClick={() => { setStep('select'); setResult(null); }}
                className="h-[30px] px-3.5 rounded-[5px] bg-transparent border border-edge text-[12px] text-ink-secondary hover:text-ink transition-colors"
              >
                Back
              </button>
              <button
                onClick={handleConfirmCreate}
                disabled={!result || result.matched_tracks === 0}
                className="h-[30px] px-4 rounded-[5px] bg-accent text-[12px] font-semibold hover:bg-accent-bright disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
                style={{ color: 'var(--color-base)' }}
              >
                {result && result.matched_tracks === 0
                  ? 'No tracks matched'
                  : `Import ${result?.matched_tracks ?? 0} tracks`}
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function Label({ children }: { children: React.ReactNode }) {
  return (
    <div className="text-[11px] text-ink-muted uppercase tracking-[0.08em] font-semibold mb-1.5">
      {children}
    </div>
  );
}
