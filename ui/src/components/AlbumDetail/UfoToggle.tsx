// Temporary stub — replaced by the full implementation in Task 2.
// This file must exist at end of Task 1 so `AlbumDetailPage.tsx` imports
// resolve during the Task 1 type-check.

interface UfoToggleProps {
  baseAlbumId: number;
  variantAlbumId: number;
  variantKind: string | null;
  selectedAlbumId: number;
  onSelect: (newSelectedAlbumId: number) => void;
}

export function UfoToggle(_props: UfoToggleProps): null {
  return null;
}
