interface FolderTreeBannerProps {
  mounted: boolean;
}

export default function FolderTreeBanner({ mounted }: FolderTreeBannerProps) {
  if (mounted) return null;

  return (
    <div
      className="px-3 py-2 bg-caution/10 border-b border-caution/30 text-[12px] text-ink-secondary leading-relaxed"
      style={{ fontFamily: "var(--font-ui)" }}
    >
      <span className="font-medium text-caution">Library drive disconnected</span>
      <span className="block mt-0.5">
        Folder list shown from index — reveal &amp; playback disabled.
      </span>
    </div>
  );
}
