import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { toast } from "sonner";

interface FolderTreeContextMenuProps {
  folderPath: string; // relative organized_path prefix
  position: { x: number; y: number };
  onClose: () => void;
  disabled?: boolean; // true when library drive disconnected (D-14)
}

export default function FolderTreeContextMenu({
  folderPath,
  position,
  onClose,
  disabled,
}: FolderTreeContextMenuProps) {
  const menuRef = useRef<HTMLDivElement>(null);

  // Close on click outside
  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    };
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [onClose]);

  // Close on Escape
  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [onClose]);

  const handleRevealInFinder = async () => {
    if (disabled) {
      toast.error("Library drive not mounted.");
      onClose();
      return;
    }
    try {
      await invoke("reveal_in_file_manager", {
        path: folderPath,
        fallbackPath: null,
      });
    } catch (err) {
      toast.error(`Could not reveal folder: ${err}`);
    }
    onClose();
  };

  const handleCopyPath = async () => {
    try {
      await invoke("copy_to_clipboard", { text: folderPath });
      toast.success("Folder path copied");
    } catch (err) {
      toast.error(`Could not copy path: ${err}`);
    }
    onClose();
  };

  return (
    <div
      ref={menuRef}
      className="fixed z-50 bg-surface border border-edge rounded-md shadow-lg py-1 min-w-[180px]"
      style={{ top: position.y, left: position.x, fontFamily: "var(--font-ui)" }}
    >
      <button
        className={`w-full px-3 py-1.5 text-left text-[13px] transition-colors ${
          disabled
            ? "text-ink-muted opacity-40 pointer-events-none"
            : "text-ink hover:bg-raised"
        }`}
        onClick={handleRevealInFinder}
        disabled={disabled}
      >
        Reveal in Finder
      </button>
      <button
        className="w-full px-3 py-1.5 text-left text-[13px] text-ink hover:bg-raised transition-colors"
        onClick={handleCopyPath}
      >
        Copy Folder Path
      </button>
    </div>
  );
}
