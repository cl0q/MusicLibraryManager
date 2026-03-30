import { useState } from 'react';
import { open } from '@tauri-apps/plugin-dialog';
import { importPlaylistFromFile, type ImportPlaylistResult } from '../../utils/tauri-commands';
import { MatchPreview } from './MatchPreview';

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
        filters: [
          { name: 'Playlist files', extensions: ['m3u', 'm3u8', 'json'] },
        ],
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
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      onClick={handleBackdropClick}
    >
      <div className="bg-surface border border-edge rounded-lg shadow-xl w-full max-w-md mx-4 flex flex-col gap-4 p-6">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold">Import Playlist</h2>
          <button
            onClick={onClose}
            className="text-ink-muted hover:text-ink transition-colors text-xl leading-none"
            aria-label="Close"
          >
            &times;
          </button>
        </div>

        {step === 'select' && (
          <>
            {/* File picker */}
            <div className="flex flex-col gap-2">
              <label className="text-[13px] font-medium">Playlist file</label>
              <div className="flex items-center gap-2">
                <div className="flex-1 px-3 py-1.5 bg-raised border border-edge rounded text-[13px] text-ink-muted truncate">
                  {filePath
                    ? (filePath.split('/').pop() ?? filePath.split('\\').pop() ?? filePath)
                    : 'No file selected'}
                </div>
                <button
                  onClick={handlePickFile}
                  className="px-3 py-1.5 text-xs font-medium bg-raised border border-edge rounded hover:bg-surface-hover transition-colors whitespace-nowrap"
                >
                  Browse
                </button>
              </div>
              <p className="text-xs text-ink-muted">Supported: .m3u, .m3u8, Spotify .json export</p>
            </div>

            {/* Playlist name */}
            <div className="flex flex-col gap-2">
              <label className="text-[13px] font-medium">Playlist name</label>
              <input
                type="text"
                value={playlistName}
                onChange={e => setPlaylistName(e.target.value)}
                placeholder="Enter playlist name"
                className="px-3 py-1.5 text-[13px] bg-raised border border-edge rounded text-ink placeholder-ink-muted focus:outline-none focus:border-accent/50"
              />
            </div>

            {error && <p className="text-rose-400 text-sm">{error}</p>}

            {/* Actions */}
            <div className="flex justify-end gap-2 pt-2">
              <button
                onClick={onClose}
                className="px-3 py-1.5 text-xs text-ink-muted hover:text-ink transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleImport}
                disabled={!filePath || !playlistName.trim() || loading}
                className="px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                {loading ? 'Matching...' : 'Preview Matches'}
              </button>
            </div>
          </>
        )}

        {step === 'preview' && result && (
          <>
            <MatchPreview result={result} />

            {error && <p className="text-rose-400 text-sm">{error}</p>}

            {/* Actions */}
            <div className="flex justify-end gap-2 pt-2">
              <button
                onClick={() => { setStep('select'); setResult(null); }}
                className="px-3 py-1.5 text-xs text-ink-muted hover:text-ink transition-colors"
              >
                Back
              </button>
              <button
                onClick={handleConfirmCreate}
                disabled={result.matched_tracks === 0}
                className="px-3 py-1.5 text-xs font-medium bg-accent hover:bg-accent-bright text-base rounded disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                {result.matched_tracks === 0
                  ? 'No tracks matched'
                  : `Create Playlist (${result.matched_tracks} tracks)`}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
