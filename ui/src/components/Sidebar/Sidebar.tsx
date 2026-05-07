import type { ReactElement } from "react";
import { NavLink, useLocation } from "react-router";
import { useLibraryMount } from "../../contexts/LibraryMountContext";

/**
 * Left navigation shell — 192px wide, matches shell.jsx mock.
 *
 * Visual contract:
 * - App identity header (44px) with Solar logo mark + uppercase label.
 * - Nav items (Library, Playlists, Sync, Sources) each expose ⌘1–⌘4 kbd hints
 *   on hover and when active.
 * - Settings pinned to footer with its own border separator.
 */

interface NavItem {
  path: string;
  label: string;
  kbd: string;
  icon: ReactElement;
  matchPrefix?: string;
  alsoMatch?: (pathname: string) => boolean;
}

export default function Sidebar() {
  const location = useLocation();
  const { isLibraryAvailable } = useLibraryMount();

  const navItems: NavItem[] = [
    {
      path: "/",
      label: "Library",
      kbd: "1",
      alsoMatch: (p) => p === "/remote" || p.startsWith("/library/"),
      icon: (
        <svg className="w-[15px] h-[15px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3" />
        </svg>
      ),
    },
    {
      path: "/playlists",
      label: "Playlists",
      kbd: "2",
      matchPrefix: "/playlists",
      icon: (
        <svg className="w-[15px] h-[15px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 12h16.5m-16.5 3.75h16.5M3.75 19.5h16.5M5.625 4.5h12.75a1.875 1.875 0 010 3.75H5.625a1.875 1.875 0 010-3.75z" />
        </svg>
      ),
    },
    {
      path: "/folders",
      label: "Folders",
      kbd: "3",
      matchPrefix: "/folders",
      icon: (
        <svg className="w-[15px] h-[15px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z" />
        </svg>
      ),
    },
    {
      path: "/sync",
      label: "Sync",
      kbd: "4",
      matchPrefix: "/sync",
      icon: (
        <svg className="w-[15px] h-[15px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M16 9h5V4M3 20v-5h5M3 15a9 9 0 0015.4 3.4M21 9a9 9 0 00-15.4-3.4" />
        </svg>
      ),
    },
    {
      path: "/sources",
      label: "Sources",
      kbd: "5",
      matchPrefix: "/sources",
      icon: (
        <svg className="w-[15px] h-[15px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m13.35-.622l1.757-1.757a4.5 4.5 0 00-6.364-6.364l-4.5 4.5a4.5 4.5 0 001.242 7.244" />
        </svg>
      ),
    },
  ];

  return (
    <aside
      className="w-48 h-full bg-surface border-r border-edge flex flex-col shrink-0"
      style={{ fontFamily: "var(--font-ui)" }}
    >
      {/* App identity header — 44px tall to match mock */}
      <div className="px-4 h-11 flex items-center gap-2.5 border-b border-edge-subtle">
        <LogoMark />
        <span className="text-[10.5px] font-bold tracking-[0.22em] uppercase text-ink-secondary">
          Music Library
        </span>
      </div>

      {/* Navigation */}
      <nav className="flex-1 p-2 flex flex-col gap-px">
        {navItems.map((item) => {
          const pathname = location.pathname;
          const active =
            pathname === item.path ||
            (item.matchPrefix && pathname.startsWith(item.matchPrefix + "/")) ||
            (item.matchPrefix && pathname === item.matchPrefix) ||
            (item.alsoMatch ? item.alsoMatch(pathname) : false);

          return (
            <NavLink
              key={item.path}
              to={item.path}
              end={item.path === "/"}
              className={`group flex items-center gap-2.5 px-2.5 py-[7px] rounded-[5px] text-[13px] transition-colors ${
                active
                  ? "bg-raised text-accent font-medium"
                  : "text-ink-secondary hover:text-ink hover:bg-raised/50"
              }`}
            >
              <span className="flex items-center justify-center w-4 h-4 shrink-0">{item.icon}</span>
              <span className="flex-1">{item.label}</span>
              {item.label === "Folders" && !isLibraryAvailable && (
                <span
                  className="w-1.5 h-1.5 rounded-full bg-accent shrink-0"
                  title="Library drive disconnected"
                />
              )}
              <Kbd active={Boolean(active)}>⌘{item.kbd}</Kbd>
            </NavLink>
          );
        })}
      </nav>

      {/* Settings pinned to footer */}
      <div className="p-2 border-t border-edge-subtle">
        <NavLink
          to="/settings"
          className={({ isActive }) =>
            `group flex items-center gap-2.5 px-2.5 py-[7px] rounded-[5px] text-[13px] transition-colors ${
              isActive
                ? "bg-raised text-accent font-medium"
                : "text-ink-secondary hover:text-ink hover:bg-raised/50"
            }`
          }
        >
          {({ isActive }) => (
            <>
              <span className="flex items-center justify-center w-4 h-4 shrink-0">
                <svg className="w-[15px] h-[15px]" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M10.3 2.5h3.4a1 1 0 011 1l.3 2a7.3 7.3 0 012.3 1.3l1.9-.8a1 1 0 011.2.4l1.7 3a1 1 0 01-.3 1.3l-1.6 1.2a7.3 7.3 0 010 2.6l1.6 1.2a1 1 0 01.3 1.3l-1.7 3a1 1 0 01-1.2.4l-1.9-.8A7.3 7.3 0 0115 19.5l-.3 2a1 1 0 01-1 1h-3.4a1 1 0 01-1-1l-.3-2a7.3 7.3 0 01-2.3-1.3l-1.9.8a1 1 0 01-1.2-.4l-1.7-3a1 1 0 01.3-1.3l1.6-1.2a7.3 7.3 0 010-2.6L2.2 9.3a1 1 0 01-.3-1.3l1.7-3a1 1 0 011.2-.4l1.9.8A7.3 7.3 0 019 4.5l.3-2a1 1 0 011-1zM12 9a3 3 0 100 6 3 3 0 000-6z" />
                </svg>
              </span>
              <span className="flex-1">Settings</span>
              <Kbd active={isActive}>⌘,</Kbd>
            </>
          )}
        </NavLink>
      </div>
    </aside>
  );
}

/* ── Atoms ─────────────────────────────────────────────── */

function LogoMark() {
  // 4-bar logo mark from the shell mock — evokes an audio spectrum
  return (
    <div className="relative w-4 h-4 shrink-0">
      <span className="absolute left-0 top-1 w-0.5 h-2 bg-accent" />
      <span className="absolute left-1 top-[1px] w-0.5 h-[14px] bg-accent" />
      <span className="absolute left-2 top-1.5 w-0.5 h-1 bg-accent" />
      <span className="absolute left-3 top-[2px] w-0.5 h-3 bg-accent" />
    </div>
  );
}

function Kbd({ children, active }: { children: React.ReactNode; active: boolean }) {
  return (
    <span
      className={`inline-flex items-center justify-center min-w-4 h-4 px-1 rounded-[3px] border border-edge bg-raised text-ink-muted tabular-nums transition-opacity ${
        active ? "opacity-60" : "opacity-0 group-hover:opacity-100"
      }`}
      style={{
        fontFamily: "var(--font-mono)",
        fontSize: 10,
        fontWeight: 500,
      }}
    >
      {children}
    </span>
  );
}
