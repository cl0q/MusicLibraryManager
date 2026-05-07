import { useState, useCallback, useRef, useEffect } from "react";
import { Tree, NodeRendererProps } from "react-arborist";
import { listFolderChildren } from "../../utils/tauri-commands";
import type { FolderNode as FolderNodeData } from "../../utils/tauri-commands";

// react-arborist node data shape
interface TreeNodeData {
  id: string; // full_path
  name: string; // segment name
  trackCount: number;
  children?: TreeNodeData[] | null; // null = not yet loaded (lazy)
}

interface FolderTreeProps {
  onFolderSelect: (folderPath: string) => void;
  onNodeContextMenu?: (e: React.MouseEvent, folderPath: string) => void;
  selectedFolder: string | null;
  showDotPrefixed: boolean;
  /** Triggers cache clear + reload */
  refreshKey: number;
}

export default function FolderTree({
  onFolderSelect,
  onNodeContextMenu,
  selectedFolder,
  showDotPrefixed,
  refreshKey,
}: FolderTreeProps) {
  const [data, setData] = useState<TreeNodeData[]>([]);
  const [loading, setLoading] = useState(true);
  const cacheRef = useRef<Map<string, TreeNodeData[]>>(new Map());
  const treeRef = useRef<any>(null);

  const mapNodes = useCallback(
    (nodes: FolderNodeData[]): TreeNodeData[] =>
      nodes.map((n) => ({
        id: n.full_path,
        name: n.name,
        trackCount: n.track_count,
        children: n.has_children ? null : undefined, // null = lazy-loadable
      })),
    [],
  );

  // Load top-level on mount and when refreshKey/showDotPrefixed changes
  useEffect(() => {
    cacheRef.current.clear();
    setLoading(true);
    listFolderChildren(undefined, !showDotPrefixed)
      .then((nodes) => {
        const mapped = mapNodes(nodes);
        cacheRef.current.set("__root__", mapped);
        setData(mapped);
      })
      .catch((err) => console.error("Failed to load root folders:", err))
      .finally(() => setLoading(false));
  }, [refreshKey, showDotPrefixed, mapNodes]);

  // Lazy-load children when a node is expanded
  const onToggle = useCallback(
    async (id: string) => {
      if (cacheRef.current.has(id)) return; // already loaded

      const children = await listFolderChildren(id, !showDotPrefixed);
      const mapped = mapNodes(children);
      cacheRef.current.set(id, mapped);

      // Update tree data immutably
      setData((prev) => updateChildren(prev, id, mapped));
    },
    [showDotPrefixed, mapNodes],
  );

  // Recursive helper to inject children into the tree
  const updateChildren = (
    nodes: TreeNodeData[],
    parentId: string,
    children: TreeNodeData[],
  ): TreeNodeData[] =>
    nodes.map((node) => {
      if (node.id === parentId) {
        return { ...node, children };
      }
      if (node.children && node.children.length > 0) {
        return { ...node, children: updateChildren(node.children, parentId, children) };
      }
      return node;
    });

  const handleSelect = useCallback(
    (nodes: any[]) => {
      if (nodes.length > 0 && nodes[0]?.data?.id) {
        onFolderSelect(nodes[0].data.id);
      }
    },
    [onFolderSelect],
  );

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full text-ink-muted text-[13px]">
        Loading folders…
      </div>
    );
  }

  return (
    <Tree
      ref={treeRef}
      data={data}
      openByDefault={false}
      width="100%"
      indent={16}
      rowHeight={36}
      onSelect={handleSelect}
      onToggle={onToggle}
      selection={selectedFolder ?? undefined}
      disableMultiSelection
    >
      {(props: NodeRendererProps<TreeNodeData>) => (
        <FolderNodeRenderer {...props} onContextMenu={onNodeContextMenu} />
      )}
    </Tree>
  );
}

// Custom node renderer matching Solar density (36px row height, IBM Plex)
function FolderNodeRenderer({
  node,
  style,
  dragHandle,
  onContextMenu,
}: NodeRendererProps<TreeNodeData> & {
  onContextMenu?: (e: React.MouseEvent, folderPath: string) => void;
}) {
  const isSelected = node.isSelected;
  const isOpen = node.isOpen;
  const hasChildren = node.data.children !== undefined;

  return (
    <div
      ref={dragHandle}
      style={style}
      className={`flex items-center gap-1.5 px-2 cursor-pointer select-none text-[13px] transition-colors ${
        isSelected
          ? "bg-raised text-accent font-medium"
          : "text-ink-secondary hover:text-ink hover:bg-raised/50"
      }`}
      onClick={(e) => {
        e.stopPropagation();
        node.select();
        // D-09: single-click = select + populate right pane, does NOT auto-expand
      }}
      onContextMenu={(e) => {
        e.preventDefault();
        e.stopPropagation();
        node.select();
        onContextMenu?.(e, node.data.id);
      }}
    >
      {/* Disclosure triangle */}
      <span
        className={`w-3 h-3 flex items-center justify-center shrink-0 transition-transform ${
          hasChildren ? "cursor-pointer" : "invisible"
        } ${isOpen ? "rotate-90" : ""}`}
        onClick={(e) => {
          e.stopPropagation();
          node.toggle();
        }}
      >
        <svg className="w-2.5 h-2.5" fill="currentColor" viewBox="0 0 8 8">
          <path d="M2 1l4 3-4 3V1z" />
        </svg>
      </span>

      {/* Folder icon */}
      <svg
        className="w-3.5 h-3.5 shrink-0 text-ink-muted"
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
        strokeWidth={1.5}
      >
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"
        />
      </svg>

      {/* Name */}
      <span className="flex-1 truncate" style={{ fontFamily: "var(--font-ui)" }}>
        {node.data.name}
      </span>

      {/* Track count (D-11: recursive) */}
      <span className="text-[11px] text-ink-muted tabular-nums shrink-0">
        {node.data.trackCount.toLocaleString()}
      </span>
    </div>
  );
}
