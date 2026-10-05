/* MLM B1 mockups — shared behaviour: shell (window, sidebar, toolbar, player, trailing column),
   track tables, menus/sheets/popovers, states & variants, annotate mode, comment mode, feedback export.
   Plain JS, no dependencies, works from file://. See assets/AUTHORING.md. */
(function () {
  'use strict';
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
  const PAGE = (location.pathname.split('/').pop() || 'index.html').replace(/\.html$/, '') || 'index';
  const FBKEY = 'mlm-b1-fb:';
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* private mode */ } }
  };
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const el = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; };

  /* ───────── Icons (stand-ins for SF Symbols) ───────── */
  const IC = {
    sidebar: 'M2.5 3.5h11v9h-11zM6 3.5v9', chevl: 'M9.5 3.5L5 8l4.5 4.5', chevr: 'M6.5 3.5L11 8l-4.5 4.5', chevd: 'M3.5 6L8 10.5 12.5 6',
    plus: 'M8 3v10M3 8h10', play: '!M4.5 2.8v10.4L13 8z', pause: '!M4 3h3v10H4zM9 3h3v10H9z', next: '!M2.5 3.5v9L8.5 8zM8.5 3.5v9l6-4.5z', prev: '!M13.5 3.5v9L7.5 8zM7.5 3.5v9l-6-4.5z',
    queue: 'M2.5 4h8M2.5 8h8M2.5 12h5M12 9.5v4l3-2z', info: 'M8 14.5a6.5 6.5 0 100-13 6.5 6.5 0 000 13zM8 7.2v4M8 4.8v.2',
    search: 'M7 12A5 5 0 107 2a5 5 0 000 10zM10.6 10.6L14 14',
    note: 'M6 12.5V3.5l7-1.5v8.5M6 12.5a2 1.6 0 11-4 0 2 1.6 0 014 0zM13 10.5a2 1.6 0 11-4 0 2 1.6 0 014 0z',
    album: 'M3 5.5h10v8H3zM4.5 3.5h7M6 1.8h4', tag: 'M2.5 2.5h5l6 6-5 5-6-6zM5.2 5.2v.1', folder: 'M1.8 4.2h4.2l1.4 1.6h6.8v7.2H1.8z',
    sparkles: 'M6 2.5l1.2 3.3L10.5 7 7.2 8.2 6 11.5 4.8 8.2 1.5 7l3.3-1.2zM12 9.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z',
    review: 'M5.5 4.5h7v9h-7zM3.5 11.5v-9h7', list: 'M2.5 4h7M2.5 8h7M2.5 12h4M12.5 4v6.5M12.5 10.5a1.6 1.3 0 11-3.2 0 1.6 1.3 0 013.2 0zM12.5 4l2.5 1',
    device: 'M4 1.8h8v12.4H4zM5.8 3.6h4.4v3.6H5.8zM8 12.3a1.6 1.6 0 100-3.2 1.6 1.6 0 000 3.2z', drive: 'M2 9.5l1.8-6h8.4l1.8 6v3.5H2zM2 9.5h12M11.5 11.3h.1',
    activity: 'M8 14.5a6.5 6.5 0 100-13 6.5 6.5 0 000 13zM8 4.5v6M5.5 8.2L8 10.7l2.5-2.5', warn: 'M8 2.2l6.3 11.1H1.7zM8 6.5v3.2M8 11.6v.1',
    gear: 'M8 10.3a2.3 2.3 0 100-4.6 2.3 2.3 0 000 4.6zM8 1.8v2M8 12.2v2M1.8 8h2M12.2 8h2M3.6 3.6l1.4 1.4M11 11l1.4 1.4M3.6 12.4L5 11M11 5l1.4-1.4',
    more: 'M8 14.5a6.5 6.5 0 100-13 6.5 6.5 0 000 13zM5 8v.1M8 8v.1M11 8v.1',
    shuffle: 'M2 4.5h2.5l6 7H14M2 11.5h2.5l1.6-1.9M10.5 4.5H14M8.3 6.4l2.2-1.9M12.3 2.8L14 4.5l-1.7 1.7M12.3 9.8l1.7 1.7-1.7 1.7',
    speaker: 'M2.5 6v4h2.5l3.5 3V3L5 6zM11 5.5a3.5 3.5 0 010 5M12.8 3.5a6 6 0 010 9', download: 'M8 2.5v8M4.8 7.5L8 10.7l3.2-3.2M3 13.5h10',
    cloud: 'M4.5 12.5a3 3 0 01-.3-6 4 4 0 017.7.8 2.6 2.6 0 01-.4 5.2z', retry: 'M13 8a5 5 0 11-1.5-3.5M13 2.5v3h-3',
    missing: 'M4 1.8h5.5L12.5 5v9.2H4zM7 7.2a1.4 1.4 0 112 1.3c-.5.3-.7.6-.7 1.1M8.3 11.8v.1', trash: 'M3 4.5h10M6 4.5V2.8h4v1.7M4.2 4.5l.6 9h6.4l.6-9',
    link: 'M6.8 9.2a2.8 2.8 0 004 0l2-2a2.8 2.8 0 00-4-4l-.8.8M9.2 6.8a2.8 2.8 0 00-4 0l-2 2a2.8 2.8 0 004 4l.8-.8', check: 'M3 8.5l3.2 3.2L13 4.5', x: 'M4 4l8 8M12 4l-8 8',
    sync: 'M13.2 6.5A5.5 5.5 0 003.4 5M2.8 9.5a5.5 5.5 0 009.8 1.5M3.2 2.5v2.7h2.7M12.8 13.5v-2.7h-2.7', video: 'M2 4h9v8H2zM11 7l3-2v6l-3-2',
    wave: 'M2 7.5v1M4 6v4M6 3.5v9M8 5.5v5M10 2.5v11M12 6v4M14 7.5v1', pencil: 'M3 13l.6-3L11 2.6l2.4 2.4L6 12.4z', clock: 'M8 14.5a6.5 6.5 0 100-13 6.5 6.5 0 000 13zM8 4.5V8l2.5 1.5',
    disc: 'M8 14.5a6.5 6.5 0 100-13 6.5 6.5 0 000 13zM8 9.8a1.8 1.8 0 100-3.6 1.8 1.8 0 000 3.6z', person: 'M8 8a2.8 2.8 0 100-5.6A2.8 2.8 0 008 8zM2.8 14c.4-2.6 2.5-4 5.2-4s4.8 1.4 5.2 4',
    globe: 'M8 14.5a6.5 6.5 0 100-13 6.5 6.5 0 000 13zM1.5 8h13M8 1.5c2.2 2.2 2.2 10.8 0 13M8 1.5c-2.2 2.2-2.2 10.8 0 13', doc: 'M4 1.8h5.5L12.5 5v9.2H4zM9.5 1.8V5h3',
    lines: 'M2.5 4h11M2.5 8h11M2.5 12h7', heart: 'M8 13.5S2 9.8 2 5.8A3 3 0 018 4.4a3 3 0 016 1.4c0 4-6 7.7-6 7.7z', photo: 'M2 3.5h12v9H2zM2 10.5l3.5-3 3 2.5 2-1.5 3.5 3M10.8 6.2v.1',
    star: 'M8 2l1.8 3.9 4.2.5-3.1 2.9.8 4.2L8 11.4l-3.7 2.1.8-4.2L2 6.4l4.2-.5z', eject: 'M8 3l5 6H3zM3 12h10', filter: 'M2.5 4h11M4.5 8h7M6.5 12h3',
    lock: 'M4 7.5h8v6H4zM5.5 7.5V5a2.5 2.5 0 015 0v2.5', share: 'M8 10V2.5M5.5 4.8L8 2.3l2.5 2.5M4 7.5H3v6h10v-6h-1', stop: '!M4 4h8v8H4z', key: 'M10.5 8.5a3 3 0 10-2.8-1.9L2.5 11.8v1.7h2v-1.3h1.3V11h1.3l1.5-1.6c.6.1 1.2.1 1.9-.9zM11 5v.1'
  };
  function icon(name, cls) {
    let d = IC[name] || IC.doc, fill = false;
    if (d[0] === '!') { fill = true; d = d.slice(1); }
    return '<svg class="i ' + (fill ? 'fill ' : '') + (cls || '') + '" viewBox="0 0 16 16" aria-hidden="true"><path d="' + d + '"/></svg>';
  }
  function hydrateIcons(root) {
    $$('i[data-i]', root).forEach(i => { const s = el(icon(i.dataset.i, i.className)); i.replaceWith(s); });
  }

  /* ───────── Demo data ───────── */
  function rng(seed) { let s = seed >>> 0; return () => (s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296; }
  const ARTISTS = ['Skee Mask', 'DJ Koze', 'Overmono', 'Call Super', 'Objekt', 'Batu', 'Shanti Celeste', 'Floating Points', 'Four Tet', 'Burial', 'Peggy Gou', 'Barker', 'Pangaea', 'Joy Orbison', 'Ross From Friends', 'Leon Vynehall', 'Avalon Emerson', 'Bicep', 'DJ Python', 'Kelela', 'Yeat', 'Caribou', 'Daphni', 'Jamie xx', 'Moodymann', 'Theo Parrish', 'Octo Octa', 'Eris Drew', 'Ploy', 'Hodge', 'Aphex Twin', 'Boards of Canada', 'Actress', 'Laurel Halo', 'Pearson Sound', 'Mall Grab', 'Palms Trax', 'Roza Terenzi', 'D. Tiffany', 'Lone'];
  const TA = ['Midnight', 'Glass', 'Soft', 'Northern', 'Blue', 'Paper', 'Slow', 'Hollow', 'Velvet', 'Silver', 'Second', 'Broken', 'Open', 'Night', 'Summer', 'Static', 'Low', 'Inner', 'Lost', 'Warm', 'Cold', 'Liquid', 'Distant', 'Neon', 'Quiet'];
  const TB = ['Signal', 'Rooms', 'Tide', 'Motion', 'Garden', 'Circuit', 'Weather', 'Pattern', 'Echo', 'Drift', 'Line', 'Hours', 'Engine', 'Mirror', 'Season', 'Light', 'Body', 'Dust', 'Bloom', 'Return', 'Theme', 'Loop', 'Shore', 'Pulse', 'Letters'];
  const SUF = ['', '', '', '', '', '', ' (Original Mix)', ' (Extended Mix)', ' (Club Edit)', ' — Live at Dekmantel 2024', ' (feat. Kelela)', ' (Overmono Remix)', ' (2021 Remaster)', ' [FREE DL]', ' (Dub)'];
  const ALBUMS = ['Compro', 'Knock Knock', 'Good Lies', 'Arpo', 'Cocoon Crush', 'Opal', 'Tangerine', 'Crush', 'Sixteen Oceans', 'Untrue', 'I Hear You', 'Stochastic Drift', 'Changes in Air', 'still slipping vol. 1', 'Tread', 'Rare, Forever', 'Charm', 'Isles', 'Mas Amable', 'Raven', 'Suddenly', 'Cherry', 'In Colour', 'Selected Ambient Works 85–92', 'Music Has the Right to Children', 'Karma & Desire', 'Dust', 'Reality Testing'];
  const GENRES = ['Techno', 'House', 'Breaks', 'UK Garage', 'Ambient', 'Electro', 'Jungle', 'Deep House', 'IDM', 'Hip-Hop', 'Dub Techno', 'Trance', 'Disco', 'Downtempo'];
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct'];
  const REASONS = ['Not available on SoundCloud any more', 'Sign-in expired (SoundCloud)', 'yt-dlp not found', 'No match found on any source', 'Network timed out'];
  function tracks(n, seed, o) {
    const r = rng(seed || 7), out = []; o = o || {};
    for (let i = 0; i < n; i++) {
      const p = r(), noAlbum = r() < 0.46; let dd;
      let status = 'local';
      if (o.allLocal) status = 'local'; else if (p > 0.992) status = 'missing'; else if (p > 0.965) status = 'failed'; else if (p > 0.955) status = 'downloading'; else if (p > 0.70) status = 'notdl';
      const an = r() < 0.72 && status === 'local', m = (r() * 10) | 0, src = ['sc', 'sc', 'yt', 'sp', '', ''][(r() * 6) | 0];
      out.push({
        id: 't' + (seed || 7) + '-' + i, title: TA[(r() * TA.length) | 0] + ' ' + TB[(r() * TB.length) | 0] + (r() < 0.3 ? SUF[(r() * SUF.length) | 0] : ''),
        artist: ARTISTS[(r() * ARTISTS.length) | 0], album: noAlbum ? '' : ALBUMS[(r() * ALBUMS.length) | 0], time: 150 + ((r() * 330) | 0),
        bpm: an ? 92 + ((r() * 60) | 0) : null, energy: an ? 1 + ((r() * 5) | 0) : null, dance: an ? 1 + ((r() * 5) | 0) : null,
        genre: r() < 0.82 ? GENRES[(r() * GENRES.length) | 0] : '', year: r() < 0.7 ? 2008 + ((r() * 18) | 0) : null,
        format: status === 'local' || status === 'missing' ? ['FLAC', 'M4A', 'M4A', 'MP3', 'ALAC'][(r() * 5) | 0] : '', kbps: status === 'local' ? [248, 320, 256, 1411, 921][(r() * 5) | 0] : null,
        added: MON[m] + ' ' + (dd = 1 + ((r() * (m === 9 ? 4 : 27)) | 0)) + ', 2026', addedSort: m * 31 + dd + i / 1e5, status, reason: REASONS[(r() * REASONS.length) | 0], attempts: 1 + ((r() * 3) | 0), source: src, c: 1 + ((r() * 6) | 0)
      });
    }
    return out;
  }
  const fmtTime = s => Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
  const fmtDur = s => { const m = Math.round(s / 60); return m < 90 ? m + ' min' : Math.floor(m / 60) + ' h ' + (m % 60) + ' min'; };
  const STATUS = {
    local: '', notdl: '<span class="status">' + icon('cloud', 's') + 'Not downloaded</span>', downloading: '<span class="status"><span class="spinner"></span>Downloading…</span>',
    failed: '<span class="status failed">' + icon('retry', 's') + 'Download failed</span>', missing: '<span class="status missing">' + icon('missing', 's') + 'File missing</span>',
    notinlib: '<span class="status">Not in library</span>'
  };
  const meter = v => v == null ? '<span class="t3">—</span>' : '<span class="num">' + v + '</span><span class="meter">' + [1, 2, 3, 4, 5].map(k => '<i' + (k <= v ? ' class="f"' : '') + '></i>').join('') + '</span>';
  const dash = v => v ? esc(v) : '<span class="t3">—</span>';
  const COLS = {
    num: { label: '#', w: 38, cls: 'r num dim', render: (t, i) => t.num || i + 1, note: 'Position in this container’s own order.' },
    title: { label: 'Title', w: 'auto', render: t => '<div class="cellt"><span class="cov c' + t.c + (t.status === 'notdl' || t.status === 'failed' ? ' none' : '') + '">' + (t.status === 'notdl' || t.status === 'failed' ? icon('note', 's') : '') + '</span><span class="ttl">' + esc(t.title) + '</span></div>', sort: 'title' },
    artist: { label: 'Artist', w: 150, render: t => esc(t.artist), sort: 'artist' },
    album: { label: 'Album', w: 160, cls: 'dim', render: t => dash(t.album), sort: 'album' },
    time: { label: 'Time', w: 52, cls: 'r num', render: t => fmtTime(t.time), sort: 'time' },
    bpm: { label: 'BPM', w: 48, cls: 'r num', render: t => t.bpm || '<span class="t3">—</span>', sort: 'bpm' },
    energy: { label: 'Energy', w: 70, render: t => meter(t.energy), sort: 'energy' },
    dance: { label: 'Dance', w: 70, render: t => meter(t.dance), sort: 'dance' },
    genre: { label: 'Genre', w: 100, render: t => dash(t.genre), sort: 'genre' },
    year: { label: 'Year', w: 48, cls: 'r num', render: t => t.year || '<span class="t3">—</span>', sort: 'year' },
    format: { label: 'Format', w: 58, render: t => dash(t.format), sort: 'format' },
    kbps: { label: 'kbps', w: 50, cls: 'r num', render: t => t.kbps || '<span class="t3">—</span>', sort: 'kbps' },
    added: { label: 'Added', w: 104, cls: 'num dim', render: t => esc(t.added), sort: 'addedSort' },
    status: { label: 'Status', w: 146, render: t => STATUS[t.status] || '', sort: 'status' }
  };

  /* ───────── Track table (SwiftUI Table stand-in) ───────── */
  const tables = [];
  function table(host, o) {
    if (typeof host === 'string') host = $(host);
    o = Object.assign({ cols: ['title', 'artist', 'album', 'time', 'bpm', 'energy', 'genre', 'added', 'status'], ids: {}, rows: [], menu: 'cm-track', sort: null, desc: false, screen: document.body.dataset.screen || '' }, o);
    host.classList.add('table'); host.tabIndex = 0;
    let rows = o.rows.slice(), filter = null, sel = new Set(), anchor = -1, sortKey = o.sort, desc = o.desc, view = [];
    function compute() {
      view = filter ? rows.filter(filter) : rows.slice();
      if (sortKey) view.sort((a, b) => { const x = a[sortKey], y = b[sortKey]; const c = (x == null ? -1 : y == null ? 1 : x < y ? -1 : x > y ? 1 : 0); return desc ? -c : c; });
    }
    function draw() {
      compute();
      const off = document.documentElement.dataset.drive === 'off';
      const head = o.cols.map(k => { const c = COLS[k]; const id = o.ids[k]; return '<th class="' + (c.cls || '').replace('dim', '') + (c.sort === sortKey ? ' sorted' : '') + '" style="' + (c.w === 'auto' ? '' : 'width:' + c.w + 'px') + '" data-col="' + k + '"' + (id ? ' data-fb-id="' + id + '" data-fb-label="' + c.label + ' column"' + (o.notes && o.notes[k] ? ' data-fb-note="' + esc(o.notes[k]) + '"' : '') + ' data-fb-api="TableColumn"' : '') + '>' + c.label + (c.sort === sortKey ? '<span class="arr">' + (desc ? '▼' : '▲') + '</span>' : '') + '</th>'; }).join('');
      const body = view.map((t, i) => '<tr data-i="' + i + '" class="' + (sel.has(t.id) ? 'sel ' : '') + (t.playing ? 'playing ' : '') + (off && (t.status === 'local' || t.status === 'missing') ? 'off ' : '') + (o.rowClass ? o.rowClass(t) : '') + '">' +
        o.cols.map(k => { const c = COLS[k]; let h = c.render(t, i); if (k === 'status' && off && (t.status === 'missing')) h = ''; if (k === 'title' && o.subline) h = h.replace('</span></div>', '<small class="sub2">' + o.subline(t) + '</small></span></div>'); return '<td class="' + (c.cls || '') + '">' + h + '</td>'; }).join('') + '</tr>').join('');
      const st = host.scrollTop;
      const minw = o.cols.reduce((n, k) => n + (COLS[k].w === 'auto' ? 200 : COLS[k].w), 0);
      host.innerHTML = '<table style="min-width:' + minw + 'px"><thead><tr>' + head + '</tr></thead><tbody>' + (body || '') + '</tbody></table>' + (view.length ? '' : (o.empty || '<div class="empty" style="height:70%">' + icon('search', 'xl') + '<h2>No results</h2><p>No tracks match the current filters.</p><div class="acts"><button class="btn" data-clear-filters>Clear filters</button></div></div>'));
      host.scrollTop = st;
      emit();
    }
    function emit() { host.dispatchEvent(new CustomEvent('mlm:select', { bubbles: true, detail: { rows: view.filter(t => sel.has(t.id)), total: view, table: api } })); }
    function paintSel() { $$('tbody tr', host).forEach(tr => tr.classList.toggle('sel', sel.has(view[+tr.dataset.i].id))); emit(); }
    function pick(i, ev) {
      if (i < 0 || i >= view.length) return;
      if (ev && ev.shiftKey && anchor >= 0) { const a = Math.min(anchor, i), b = Math.max(anchor, i); if (!(ev.metaKey || ev.ctrlKey)) sel.clear(); for (let k = a; k <= b; k++) sel.add(view[k].id); }
      else if (ev && (ev.metaKey || ev.ctrlKey)) { const id = view[i].id; sel.has(id) ? sel.delete(id) : sel.add(id); anchor = i; }
      else { sel.clear(); sel.add(view[i].id); anchor = i; }
      paintSel();
      const tr = $('tbody tr[data-i="' + i + '"]', host); if (tr && tr.scrollIntoView) tr.scrollIntoView({ block: 'nearest' });
    }
    host.addEventListener('mousedown', e => {
      const th = e.target.closest('th'); if (th && !document.body.classList.contains('commenting')) { const c = COLS[th.dataset.col]; if (c && c.sort && e.button === 0) { if (sortKey === c.sort) desc = !desc; else { sortKey = c.sort; desc = false; } draw(); } return; }
      const tr = e.target.closest('tbody tr'); if (!tr) return; const i = +tr.dataset.i;
      if (e.button === 2 && sel.has(view[i].id)) return;
      pick(i, e.button === 2 ? null : e);
    });
    host.addEventListener('dblclick', e => { const tr = e.target.closest('tbody tr'); if (tr) shell.play(view[+tr.dataset.i], api); });
    host.addEventListener('contextmenu', e => { const tr = e.target.closest('tbody tr'); const th = e.target.closest('th'); if (th) { e.preventDefault(); openMenu('cm-columns', e.clientX, e.clientY); } else if (tr && o.menu) { e.preventDefault(); openMenu(o.menu, e.clientX, e.clientY, { rows: api.selection() }); } });
    host.addEventListener('keydown', e => {
      const cur = anchor >= 0 ? anchor : -1;
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); const n = Math.max(0, Math.min(view.length - 1, cur + (e.key === 'ArrowDown' ? 1 : -1))); pick(n, e.shiftKey ? { shiftKey: true } : null); if (!e.shiftKey) anchor = n; if (shell.previewing) shell.preview(view[n]); }
      else if (e.key === ' ') { e.preventDefault(); const s = api.selection(); if (shell.previewing) shell.endPreview(); else if (s.length === 1) shell.preview(s[0]); else shell.say('Space previews one selected track. Select a single track.'); }
      else if (e.key === 'Enter') { e.preventDefault(); const s = api.selection(); if (s.length) { if (e.altKey) shell.say('Playing next: ' + (s.length === 1 ? '“' + esc(s[0].title) + '”' : s.length + ' tracks'), true); else shell.play(s[0], api); } }
      else if (e.key === 'a' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); view.forEach(t => sel.add(t.id)); paintSel(); }
      else if (e.key === 'Escape') { if (shell.previewing) shell.endPreview(); else { sel.clear(); paintSel(); } }
      else if ((e.key === 'Backspace' || e.key === 'Delete') && o.onDelete) { e.preventDefault(); o.onDelete(api.selection()); }
    });
    host.addEventListener('click', e => { if (e.target.closest('[data-clear-filters]')) { filter = null; const sb = $('.scopebar .scope'); if (sb) sb.click(); const sf = $('.search'); if (sf) sf.value = ''; draw(); } });
    const api = {
      el: host, opts: o, draw, selection: () => view.filter(t => sel.has(t.id)), view: () => view, all: () => rows,
      setRows(r) { rows = r.slice(); sel.clear(); anchor = -1; draw(); }, setFilter(f) { filter = f; draw(); },
      setCols(c) { o.cols = c; draw(); }, select(ids) { sel = new Set(ids); paintSel(); }, markPlaying(t) { rows.forEach(x => { x.playing = t && x.id === t.id; }); draw(); }
    };
    tables.push(api); draw(); return api;
  }

  /* ───────── Shell ───────── */
  const NAV = [
    { h: 'Library', id: 'P-SIDEBAR.E01' },
    { k: 'tracks', l: 'All Tracks', i: 'note', href: 'library.html', id: 'P-SIDEBAR.E02', note: 'Was “Library”. Shows every track of the open library.', dec: 'DEC-002' },
    { k: 'albums', l: 'Albums', i: 'album', href: 'albums.html', id: 'P-SIDEBAR.N01', note: 'New. Album grid → album detail.', dec: 'DEC-019' },
    { k: 'genres', l: 'Genres', i: 'tag', href: 'genres.html', id: 'P-SIDEBAR.N02', note: 'New home of the Genre Workshop.', dec: 'DEC-025' },
    { k: 'folders', l: 'Folders', i: 'folder', href: 'folders.html', id: 'P-SIDEBAR.E04', note: 'Disk folders under the library folder.', dec: 'DEC-024' },
    { h: 'Inbox', id: 'P-SIDEBAR.E07' },
    { k: 'discover', l: 'Discover', i: 'sparkles', href: 'discover.html', badge: '7', id: 'P-SIDEBAR.E09', note: 'Badge = recommendations and reels waiting for a verdict.', dec: 'DEC-029' },
    { k: 'review', l: 'Review', i: 'review', href: 'review.html', badge: '14', id: 'P-SIDEBAR.E08', note: 'Badge = groups waiting (duplicates + conflicts + album suggestions).', dec: 'DEC-028' },
    { h: 'Playlists', id: 'P-SIDEBAR.E03', add: true },
    { k: 'allpl', l: 'All Playlists', i: 'photo', href: 'playlists.html', id: 'P-PINNED.E01', note: 'Opens the cover grid.', dec: 'DEC-003' },
    { k: 'plf', l: 'Sets', i: 'folder', disc: '▾', href: 'playlists.html', id: 'P-SIDEBAR.N03', note: 'Playlist folder (new). DisclosureGroup; drop target.', dec: 'DEC-003' },
    { k: 'pl1', l: 'Warm-up', i: 'list', indent: 1, href: 'playlists.html#detail', id: 'P-PINNED.E02', note: 'Every playlist is a sidebar row and accepts dropped tracks. No pin limit.', dec: 'DEC-003' },
    { k: 'pl2', l: 'Peak time', i: 'list', indent: 1, href: 'playlists.html#detail' },
    { k: 'pl3', l: 'Closing', i: 'list', indent: 1, href: 'playlists.html#detail' },
    { k: 'pl4', l: 'Liked on SoundCloud', i: 'heart', href: 'playlists.html#detail', sub: 'Importing · 12 of 44', two: 1, id: 'P-SIDEBAR.N04', note: 'A playlist that is not healthy says so in words on its second line.', dec: 'DEC-023' },
    { k: 'pl5', l: 'Boiler Room picks', i: 'list', href: 'playlists.html#detail' },
    { k: 'pl6', l: 'Road trip 2026', i: 'list', href: 'playlists.html#detail' },
    { k: 'pl7', l: 'Ambient for work', i: 'list', href: 'playlists.html#detail' },
    { h: 'Sync', id: 'P-SIDEBAR.E05', add: true },
    { k: 'sync1', l: 'iPod Classic', i: 'device', href: 'sync.html', sub: 'Not connected', two: 1, id: 'P-SIDEBAR.N05', note: 'One row per sync profile; state in words; drop target for tracks, albums and playlists.', dec: 'DEC-027' },
    { k: 'sync2', l: 'Car USB stick', i: 'drive', href: 'sync.html', sub: '12 to add', two: 1 }
  ];
  const shell = {
    previewing: null, current: null, msgTimer: 0, win: null,
    say(html, undo) {
      const sb = $('.statusbar .msg', shell.win); if (!sb) return;
      sb.innerHTML = html + (undo ? ' <a class="btn plain" style="height:16px">Undo</a>' : ''); sb.hidden = false; const d = $('.statusbar .def', shell.win); if (d) d.hidden = true;
      clearTimeout(shell.msgTimer); shell.msgTimer = setTimeout(() => { sb.hidden = true; if (d) d.hidden = false; }, 7000);
    },
    setPlayer(t, mode) {
      const p = $('.player', shell.win); if (!p) return;
      p.classList.toggle('preview', mode === 'preview'); p.classList.toggle('cant', mode === 'cant');
      const ti = $('.ti', p), ar = $('.ar', p), cov = $('.cover', p), tm = $('.time', p);
      if (!t) { ti.textContent = 'Not playing'; ar.textContent = ''; cov.className = 'cover cov none'; tm.textContent = ''; return; }
      cov.className = 'cover cov c' + (t.c || 1);
      ti.innerHTML = (mode === 'preview' ? '<span class="tag">Preview</span>' : '') + esc(t.title);
      ar.innerHTML = mode === 'preview' ? 'Space to stop · Return to play' : mode === 'cant' ? t.cant : esc(t.artist) + (t.album ? ' — ' + esc(t.album) : '');
      tm.textContent = mode === 'cant' ? '' : (mode === 'preview' ? '0:42' : '1:12') + ' / ' + fmtTime(t.time);
      const pb = $('[data-act="playpause"]', shell.win); if (pb) pb.innerHTML = icon(mode === 'cant' ? 'play' : 'pause');
    },
    play(t, tbl) {
      shell.previewing = null;
      if (document.documentElement.dataset.drive === 'off' && (t.status === 'local' || t.status === 'missing')) { shell.say(icon('drive', 's') + ' Can’t play — “Lexxar” is not connected.'); shell.setPlayer(Object.assign({}, t, { cant: 'Can’t play — “Lexxar” is not connected' }), 'cant'); return; }
      if (t.status === 'notdl' || t.status === 'failed') { shell.say('Downloading “' + esc(t.title) + '” — it will play when it’s ready. <a class="btn plain" style="height:16px">Cancel</a>'); t.status = 'downloading'; if (tbl) tbl.draw(); return; }
      if (t.status === 'downloading') { shell.say('“' + esc(t.title) + '” is still downloading.'); return; }
      if (t.status === 'missing') { shell.say(icon('missing', 's') + ' File missing — <a class="btn plain" style="height:16px">Locate…</a> <a class="btn plain" style="height:16px">Download again</a>'); return; }
      shell.current = t; shell.setPlayer(t, 'play'); tables.forEach(x => x.markPlaying(t)); if (tbl) tbl.el.focus();
    },
    preview(t) {
      if (t.status !== 'local') { shell.say(t.status === 'missing' ? 'Can’t preview — file missing.' : 'Can’t preview — not downloaded. Press ⌘D to download.'); return; }
      if (document.documentElement.dataset.drive === 'off') { shell.say(icon('drive', 's') + ' Can’t preview — “Lexxar” is not connected.'); return; }
      shell.previewing = t; shell.setPlayer(t, 'preview');
    },
    endPreview() { shell.previewing = null; shell.setPlayer(shell.current, shell.current ? 'play' : null); shell.say(shell.current ? 'Preview ended — resumed “' + esc(shell.current.title) + '”.' : 'Preview ended.'); }
  };

  function sidebarHTML(active) {
    let h = '<div class="sb-top"><div class="traffic"><i></i><i></i><i></i></div></div><div class="sb-scroll">';
    NAV.forEach(n => {
      const fb = n.id ? ' data-fb-id="' + n.id + '" data-fb-label="' + esc(n.h ? n.h + ' section header' : n.l + ' row') + '"' + (n.note ? ' data-fb-note="' + esc(n.note) + '"' : '') + (n.dec ? ' data-fb-dec="' + n.dec + '"' : '') + ' data-fb-api="' + (n.h ? 'Section' : 'List row (sidebar)') + '"' : '';
      if (n.h) { h += '<div class="sb-h"' + fb + '>' + n.h + (n.add ? '<span class="add">' + icon('plus', 's') + '</span>' : '') + '</div>'; return; }
      h += '<a class="sb-row' + (n.k === active ? ' active' : '') + (n.indent ? ' indent' : '') + (n.two ? ' two' : '') + '" href="' + n.href + '" data-nav="' + n.k + '"' + fb + '>' + (n.disc ? '<span class="disc">' + n.disc + '</span>' : '') + icon(n.i) +
        '<span class="lbl trunc">' + n.l + (n.sub ? '<small>' + n.sub + '</small>' : '') + '</span>' + (n.badge ? '<span class="badge">' + n.badge + '</span>' : '') + '</a>';
    });
    h += '</div><div class="sb-foot" data-menu-click="m-library" data-fb-id="P-LIBFOOTER" data-fb-label="Library footer (switcher)" data-fb-note="Names the open library and the drive state in words. Click: Open Recent, Open Library…, New Library…, Show Library File in Finder." data-fb-dec="DEC-031" data-fb-api="safeAreaInset(edge: .bottom) + Menu">' + icon('disc') + '<span class="lbl trunc">Main Library<small class="drive-on">12,935 tracks</small><small class="drive-off warn">“Lexxar” — not connected</small></span><span class="t2">' + icon('chevd', 's') + '</span></div>';
    return h;
  }
  function toolbarHTML() {
    const wave = Array.from({ length: 56 }, (_, i) => '<b class="' + (i < 14 ? 'p' : '') + '" style="height:' + (3 + Math.abs(Math.sin(i * 1.7) * 9 + Math.sin(i * 0.37) * 3) | 0) + 'px"></b>').join('');
    return '<div class="tb-group"><button class="tb-btn" data-act="sidebar" title="Hide sidebar ⌃⌘S" data-fb-id="P-TOOLBAR.E01" data-fb-label="Sidebar toggle" data-fb-api="NavigationSplitView (system item)">' + icon('sidebar') + '</button></div>' +
      '<div class="tb-group" data-fb-id="P-TOOLBAR.N01" data-fb-label="Back / Forward" data-fb-note="History for pushed details (album, playlist, genre, Similar). ⌘[ / ⌘]." data-fb-api="NavigationStack path">' + '<button class="tb-btn" data-act="back">' + icon('chevl') + '</button><button class="tb-btn" disabled>' + icon('chevr') + '</button></div>' +
      '<div class="tb-group"><button class="tb-btn" data-menu-click="m-add" title="Add" data-fb-id="P-ADDMENU" data-fb-label="Add menu" data-fb-note="New Playlist, New Playlist Folder, Add from Link…, Import Playlist from Source…, Import Files or Folder…, Refresh from Sources." data-fb-dec="DEC-004" data-fb-api="ToolbarItem + Menu">' + icon('plus') + '</button></div>' +
      '<div class="tb-space"></div>' +
      '<div class="player" data-fb-id="P-PLAYER" data-fb-label="Player (toolbar, .principal)" data-fb-note="Transport, cover, title/artist, scrubber, volume, queue button. No background of its own on macOS 26 (toolbar glass groups it)." data-fb-dec="DEC-045" data-fb-api="ToolbarItem(placement: .principal)">' +
      '<button class="tb-btn" data-fb-id="P-PLAYER.E01" data-fb-label="Previous">' + icon('prev') + '</button><button class="tb-btn" data-act="playpause" data-fb-id="P-PLAYER.E02" data-fb-label="Play/Pause">' + icon('play') + '</button><button class="tb-btn" data-fb-id="P-PLAYER.E03" data-fb-label="Next" data-fb-note="Skips unplayable tracks and says so in the status bar." data-fb-dec="DEC-045">' + icon('next') + '</button>' +
      '<span class="cover cov none" data-fb-id="P-PLAYER.E04" data-fb-label="Cover (click: large cover popover)"></span>' +
      '<div class="meta" data-fb-id="P-PLAYER.E05" data-fb-label="Title / artist / state line" data-fb-note="States in words: Not playing · Preview · Can’t play — not downloaded / file missing / drive not connected. Click = go to current track (⌘L)."><div class="ti trunc">Not playing</div><div class="ar trunc"></div><div class="scrub" data-fb-id="P-PLAYER.E09" data-fb-label="Scrubber (waveform while previewing)"><i></i><div class="wave">' + wave + '</div></div></div>' +
      '<span class="time" data-fb-id="P-PLAYER.E08" data-fb-label="Elapsed / duration"></span>' +
      '<button class="tb-btn" data-fb-id="P-PLAYER.E10" data-fb-label="Volume (persisted)">' + icon('speaker') + '</button>' +
      '<button class="tb-btn" data-act="queue" title="Queue ⌥⌘U" data-fb-id="P-PLAYER.N01" data-fb-label="Queue button" data-fb-note="Opens the Queue mode of the trailing column." data-fb-dec="DEC-006">' + icon('queue') + '</button></div>' +
      '<div class="tb-space"></div>' +
      '<div class="tb-group"><button class="tb-btn" data-popover="p-activity" data-fb-id="P-ACTIVITY" data-fb-label="Activity item" data-fb-note="Idle: icon. Running: ring + short text. Needs attention: text stays (“9 failed”). Click: popover. ⌥⌘0: Activity window." data-fb-dec="DEC-005" data-fb-api="ToolbarItem + popover; ProgressView(.circular)">' + '<span class="spinner"></span><span class="txt">Downloading 12 of 44</span><span class="txt attn">· 9 failed</span></button></div>' +
      '<div class="tb-group"><button class="tb-btn" data-act="info" title="Info ⌘I" data-fb-id="P-TOOLBAR.N02" data-fb-label="Inspector toggle" data-fb-dec="DEC-007" data-fb-api=".inspector(isPresented:)">' + icon('info') + '</button></div>' +
      '<div class="search-wrap" data-fb-id="V-SEARCH.E01" data-fb-label="Search field" data-fb-note="System search field. Typing filters the current view in place; scopes and tokens appear while searching; a pasted link offers Add from Link." data-fb-dec="DEC-017" data-fb-api=".searchable(text:tokens:) + .searchScopes">' + icon('search', 's') + '<input class="search" placeholder="Search" spellcheck="false"></div>';
  }
  function trailingHTML() {
    return '<div class="tr-head"><div class="seg" data-group="trail"><button data-p="info" class="on">Info</button><button data-p="queue">Queue</button></div></div>' +
      '<div class="tr-body" data-pane="trail:info" data-fb-id="P-INSPECTOR" data-fb-label="Info (track inspector)" data-fb-note="Follows the selection. One track: its details. Several: the same form with “Mixed” — edits apply to all. Full design: inspector.html." data-fb-dec="DEC-007" data-fb-api=".inspector + Form"><div id="insp-auto"></div></div>' +
      '<div class="tr-body" data-pane="trail:queue" hidden data-fb-id="P-QUEUE" data-fb-label="Queue" data-fb-note="Now playing · Next · History. Drag to reorder, ⌫ to remove, Clear, Save as Playlist…. Full design: queue.html." data-fb-dec="DEC-006" data-fb-api=".inspector + List(.onMove/.onDelete)"><div id="queue-auto"></div></div>';
  }
  function inspectorAuto(rows) {
    const host = $('#insp-auto'); if (!host) return;
    if (!rows.length) { host.innerHTML = '<div class="empty">' + icon('info', 'xl') + '<h2>No selection</h2><p>Select a track to see and edit its details.</p></div>'; return; }
    const one = rows.length === 1, t = rows[0];
    const mix = k => { const v = new Set(rows.map(r => r[k] || '')); return v.size === 1 ? ' value="' + esc([...v][0]) + '"' : ' placeholder="Mixed" class="field mixed"'; };
    host.innerHTML = '<div class="row gap12" style="margin-bottom:12px"><span class="cov c' + t.c + '" style="width:54px;height:54px;border-radius:7px"></span><div class="grow"><div style="font-weight:600;white-space:normal">' + (one ? esc(t.title) : rows.length + ' tracks selected') + '</div><div class="t2 trunc">' + (one ? esc(t.artist) : fmtDur(rows.reduce((a, r) => a + r.time, 0)) + ' · edits apply to all') + '</div></div></div>' +
      '<div class="row" style="justify-content:center;margin-bottom:12px"><div class="seg"><button class="on">Details</button><button>Audio</button><button>File</button></div></div>' +
      '<div class="kv">' + (one ? '<label>Title</label><input class="field" value="' + esc(t.title) + '">' : '') +
      '<label>Artist</label><input class="field"' + mix('artist') + '><label>Album</label><input class="field"' + mix('album') + '><label>Genre</label><input class="field"' + mix('genre') + '><label>Year</label><input class="field"' + mix('year') + '><label>BPM</label><input class="field"' + mix('bpm') + '></div>' +
      (one && t.status !== 'local' ? '<p class="caption" style="margin-top:14px">' + (STATUS[t.status] || '') + (t.status === 'failed' ? '<br>' + esc(t.reason) + ' · ' + (3 - t.attempts) + ' attempts left<br><a class="btn" style="margin-top:6px">Retry download</a>' : '') + '</p>' : '') +
      '<p class="caption" style="margin-top:14px"><a href="inspector.html">Full inspector design →</a></p>';
  }
  function queueAuto() {
    const host = $('#queue-auto'); if (!host) return; const q = tracks(9, 99, { allLocal: true });
    const row = (t, extra) => '<div class="row" style="height:36px"><span class="cov c' + t.c + '" style="width:26px;height:26px"></span><div class="grow" style="line-height:1.2"><div class="trunc">' + esc(t.title) + '</div><div class="t2 small trunc">' + esc(t.artist) + (extra || '') + '</div></div><span class="t2 small num">' + fmtTime(t.time) + '</span></div>';
    host.innerHTML = '<div class="caption" style="font-weight:600">Now playing</div>' + row(q[0]) + '<div class="row" style="margin-top:10px"><span class="caption grow" style="font-weight:600">Next</span><a class="btn plain small">Clear</a></div>' + q.slice(1, 4).map(t => row(t)).join('') +
      '<div class="caption" style="margin:8px 0 2px">From “Warm-up”</div>' + q.slice(4, 7).map(t => row(t)).join('') + '<div class="caption" style="font-weight:600;margin-top:10px">History</div>' + q.slice(7).map(t => row(t)).join('') + '<p class="caption" style="margin-top:14px"><a href="queue.html">Full queue design →</a></p>';
  }
  const SHELL_OVERLAYS =
    '<div class="menu" id="m-add" hidden data-fb-id="P-ADDMENU.N01" data-fb-label="Add menu items"><a class="mi" href="playlists.html">' + icon('list') + 'New Playlist<span class="k">⌘N</span></a><a class="mi">' + icon('folder') + 'New Playlist Folder<span class="k">⌥⌘N</span></a><hr><a class="mi" href="import.html#quickadd">' + icon('link') + 'Add from Link…<span class="k">⌘U</span></a><a class="mi" href="import.html">' + icon('download') + 'Import Playlist from Source…<span class="k">⇧⌘I</span></a><a class="mi">' + icon('folder') + 'Import Files or Folder…</a><a class="mi">' + icon('doc') + 'Import M3U…</a><hr><a class="mi">' + icon('retry') + 'Refresh from Sources</a></div>' +
    '<div class="menu" id="m-library" hidden data-fb-id="P-LIBFOOTER.N01" data-fb-label="Library menu"><div class="mi hdr">Open Recent</div><a class="mi chk">Main Library</a><a class="mi nochk" href="launch.html#switch">Laptop Subset</a><a class="mi nochk dis">Archive 2019 — Not connected</a><hr><a class="mi" href="launch.html">Open Library…<span class="k">⌘O</span></a><a class="mi" href="launch.html#new">New Library…</a><hr><a class="mi">Show Library File in Finder</a><a class="mi" href="settings.html#library">Library Settings…</a></div>' +
    '<div class="menu" id="cm-columns" hidden data-fb-id="V-TRACK-TABLE.N01" data-fb-label="Column header menu" data-fb-note="Show/hide and reorder columns, persisted per view." data-fb-dec="DEC-012" data-fb-api="TableColumnCustomization"><div class="mi hdr">Columns</div><a class="mi chk">Artist</a><a class="mi chk">Album</a><a class="mi chk">Time</a><a class="mi chk">BPM</a><a class="mi chk">Energy</a><a class="mi nochk">Dance</a><a class="mi chk">Genre</a><a class="mi nochk">Year</a><a class="mi nochk">Format</a><a class="mi nochk">kbps</a><a class="mi chk">Added</a><a class="mi chk">Status</a><hr><a class="mi">Auto Size All Columns</a></div>' +
    '<div class="menu" id="cm-track" hidden data-fb-id="CM-TRACK" data-fb-label="Track context menu" data-fb-note="Same group order in every context menu: Primary · Queue · Add to · Info · Fix · Locate/Share · Remove." data-fb-dec="DEC-039" data-fb-api="contextMenu(forSelectionType:menu:primaryAction:)">' +
    '<div class="mi hdr" data-cm-count></div><a class="mi" data-fb-id="CM-TRACK.E02">' + icon('play') + 'Play<span class="k">↩</span></a><a class="mi" data-fb-id="CM-TRACK.N01">' + icon('wave') + 'Preview<span class="k">Space</span></a><hr>' +
    '<a class="mi" data-fb-id="CM-TRACK.E03">Play Next<span class="k">⌥↩</span></a><a class="mi" data-fb-id="CM-TRACK.N02">Add to Queue<span class="k">⌥⇧↩</span></a><hr>' +
    '<a class="mi sub" data-fb-id="CM-TRACK.E04">Add to Playlist</a><a class="mi sub" data-fb-id="CM-TRACK.E05">Add to Sync Profile</a><hr>' +
    '<a class="mi" data-act="info-open" data-fb-id="CM-TRACK.N03">Get Info<span class="k">⌘I</span></a><a class="mi" href="albums.html#detail" data-fb-id="CM-TRACK.N04">Go to Album</a><a class="mi" data-fb-id="CM-TRACK.N05">Go to Artist</a><a class="mi" href="discover.html#similar" data-fb-id="CM-TRACK.N06">Find Similar</a><hr>' +
    '<a class="mi" data-fb-id="CM-TRACK.E08">' + icon('download') + 'Download<span class="k">⌘D</span></a><hr>' +
    '<a class="mi" data-fb-id="CM-TRACK.E06">Show in Finder<span class="k">⇧⌘R</span></a><a class="mi sub" data-fb-id="CM-TRACK.E07">Copy</a><a class="mi" data-fb-id="CM-TRACK.N07">Share…</a><hr>' +
    '<a class="mi destr" data-open="a-track-remove" data-fb-id="CM-TRACK.E09">Remove from Library…<span class="k">⌘⌫</span></a></div>' +
    '<div class="popover" id="p-activity" hidden style="width:340px" data-fb-id="P-ACTIVITY-OPS" data-fb-label="Activity popover" data-fb-note="Running · Needs attention (grouped by cause, with the fix) · Recent (results persist). Full design: activity.html." data-fb-dec="DEC-044" data-fb-api="popover + List">' +
    '<div class="caption" style="font-weight:600">Running</div><div style="margin:6px 0 10px"><div class="row"><span class="grow trunc">Importing “Liked on SoundCloud”</span><span class="t2 small num">12 of 44</span><a class="btn plain small">Cancel</a></div><div class="progress" style="margin-top:4px"><i style="width:27%"></i></div></div>' +
    '<div class="caption" style="font-weight:600">Needs attention</div><div class="row" style="margin:6px 0 2px"><span class="status failed">' + icon('warn', 's') + '</span><span class="grow" style="white-space:normal">9 downloads failed — sign-in expired (SoundCloud)</span><a class="btn small" href="settings.html#sources">Reconnect</a></div>' +
    '<div class="caption" style="font-weight:600;margin-top:10px">Recent</div><div class="row t2" style="margin-top:4px"><span class="grow trunc">Backup finished — 12,935 tracks</span><span class="small">9:02</span></div><div class="row t2"><span class="grow trunc">Scan “Lexxar/Music/2026” — 14 imported</span><span class="small">Yesterday</span></div>' +
    '<hr style="border:0;border-top:.5px solid var(--sep);margin:10px 0 8px"><a class="btn plain" href="activity.html">Open Activity Window<span class="t2" style="margin-left:6px">⌥⌘0</span></a></div>' +
    '<div class="alert" id="a-track-remove" hidden data-fb-id="A-TRACK-REMOVE" data-fb-label="Remove from Library confirmation" data-fb-api=".confirmationDialog"><div class="aic">' + icon('trash', 'l') + '</div><h2>Remove 1 track from the library?</h2><p>Its file moves to the Trash and it is removed from 2 playlists and 1 sync profile. You can put the file back from the Trash.</p><div class="ab"><button class="btn destructive" data-close>Move to Trash</button><button class="btn" data-close>Cancel</button></div></div>';

  function buildShell() {
    const b = document.body, plain = b.dataset.shell === 'plain';
    const stage = el('<div class="stage"></div>');
    const content = $('#content');
    Array.from(b.childNodes).forEach(n => stage.appendChild(n));
    b.appendChild(stage);
    if (!plain && content) {
      const win = el('<div class="window" data-fb-id="W-MAIN" data-fb-label="Main window" data-fb-note="One main window. Title = current place, subtitle = library name." data-fb-api="Window + NavigationSplitView"><div class="win-body"><nav class="sidebar" data-fb-id="P-SIDEBAR" data-fb-label="Sidebar" data-fb-note="Library · Inbox · Playlists · Sync, footer = library switcher. Floating glass column (system)." data-fb-dec="DEC-001" data-fb-api="List(selection:).listStyle(.sidebar)">' + sidebarHTML(b.dataset.nav) + '</nav><div class="main"><div class="toolbar" data-fb-id="P-TOOLBAR" data-fb-label="Toolbar" data-fb-note="Constant in every section: no section-specific items." data-fb-dec="DEC-048" data-fb-api=".toolbar (unified); glass on macOS 26, .bar on 15">' + toolbarHTML() + '</div><div class="content-wrap"><div class="content"></div><aside class="trailing" hidden>' + trailingHTML() + '</aside></div></div></div></div>');
      content.replaceWith(win);
      const c = $('.content', win);
      c.appendChild(el('<div class="banner drive-off" data-fb-id="G-DRIVE-OFFLINE" data-fb-label="Drive not connected banner" data-fb-note="One sentence at window level instead of 12,000 File-missing chips. Shown in every view that lists tracks." data-fb-dec="DEC-014">' + icon('drive') + '<span><b>“Lexxar” is not connected.</b> You can browse, edit and queue downloads. Playback and file actions are paused.</span><span class="act"><button class="btn" data-drive-on>Try Again</button></span></div>'));
      c.appendChild(content); content.classList.add('view'); content.removeAttribute('hidden');
      if (b.dataset.selbar !== 'off') c.appendChild(el('<div class="selbar" hidden data-fb-id="P-SELBAR" data-fb-label="Selection bar" data-fb-note="Appears with 2+ selected rows. The one custom Liquid Glass surface: a control cluster floating above the rows it acts on." data-fb-dec="DEC-015" data-fb-api="GlassEffectContainer + .glassEffect(.regular.interactive(), in: .capsule); macOS 15: .regularMaterial"><span class="cnt"></span><button class="tb-btn" data-say="Playing next: {n} tracks" data-fb-id="P-SELBAR.N01" data-fb-label="Play Next">Play Next</button><button class="tb-btn" data-say="Added {n} tracks to “Warm-up”" data-fb-id="P-SELBAR.N02" data-fb-label="Add to Playlist ▾">Add to Playlist ' + icon('chevd', 's') + '</button><button class="tb-btn" data-act="info-open" data-fb-id="P-SELBAR.N03" data-fb-label="Edit Info">Edit Info</button><button class="tb-btn" data-say="Download started — {n} tracks" data-fb-id="P-SELBAR.N04" data-fb-label="Download (only if some are not downloaded)">Download</button><button class="tb-btn" data-menu-click="cm-track" data-fb-id="P-SELBAR.N05" data-fb-label="More">' + icon('more') + '</button></div>'));
      if (b.dataset.statusbar !== 'off') c.appendChild(el('<div class="statusbar" data-fb-id="P-STATUSBAR" data-fb-label="Status bar" data-fb-note="Counts for the view or the selection; transient confirmations with Undo appear here instead of toasts." data-fb-dec="DEC-016" data-fb-api="safeAreaInset(edge: .bottom)"><span class="def">' + (b.dataset.status || '') + '</span><span class="msg" hidden></span></div>'));
      shell.win = win;
    } else { shell.win = $('.window') || stage; }
    const ov = el('<div id="overlays"></div>'); ov.innerHTML = SHELL_OVERLAYS; $$('.menu,.popover,.alert,.sheet', ov).forEach(n => { if (n.id && document.getElementById(n.id) && document.getElementById(n.id) !== n) n.remove(); });
    b.appendChild(ov);
    queueAuto(); inspectorAuto([]);
    buildReviewBar();
  }

  /* ───────── Review bar, states, variants ───────── */
  function setAttrState(kind, v) {
    document.body.dataset[kind] = v;
    $$('[data-' + (kind === 'state' ? 'show' : 'variant') + ']').forEach(n => { const list = (n.dataset[kind === 'state' ? 'show' : 'variant'] || '').split(/\s+/); n.hidden = !list.includes(v); });
    if (kind === 'state') $$('[data-hide]').forEach(n => { n.hidden = n.dataset.hide.split(/\s+/).includes(v); });
    $$('.reviewbar [data-set-' + kind + ']').forEach(x => x.classList.toggle('on', x.dataset['set' + kind[0].toUpperCase() + kind.slice(1)] === v));
    document.dispatchEvent(new CustomEvent('mlm:' + kind, { detail: v }));
    refreshBadges();
  }
  function setDrive(on) { document.documentElement.dataset.drive = on ? 'on' : 'off'; store.set('mlm-b1-drive', on ? 'on' : 'off'); $$('.drive-off').forEach(n => n.hidden = on); $$('.drive-on').forEach(n => n.hidden = !on); $$('.reviewbar [data-drive]').forEach(x => x.classList.toggle('on', (x.dataset.drive === 'on') === on)); tables.forEach(t => t.draw()); refreshBadges(); }
  function setTheme(t) { document.documentElement.dataset.theme = t; store.set('mlm-b1-theme', t); const x = $('.reviewbar [data-act="theme"]'); if (x) x.textContent = t === 'dark' ? 'Light' : 'Dark'; }
  function buildReviewBar() {
    const b = document.body, states = (b.dataset.states || '').split(',').filter(Boolean), vars = (b.dataset.variants || '').split(',').filter(Boolean), rec = b.dataset.variantRec || vars[0];
    const lab = s => ({ default: 'Default', empty: 'Empty', loading: 'Loading', error: 'Error', huge: 'Huge', offline: 'Drive off' }[s] || s.replace(/-/g, ' ').replace(/^./, c => c.toUpperCase()));
    let h = '<div class="reviewbar"><a class="rb" href="index.html">‹ Index</a><b>' + esc(b.dataset.title || document.title) + '</b><span class="sid">' + esc(b.dataset.screen || '') + '</span>';
    if (states.length) h += '<span class="grp"><span>State</span>' + states.map(s => '<button class="rb" data-set-state="' + s + '">' + lab(s) + '</button>').join('') + '</span>';
    if (vars.length) h += '<span class="grp"><span>Variant' + (b.dataset.variantDec ? ' (' + b.dataset.variantDec + ')' : '') + '</span>' + vars.map(s => '<button class="rb' + (s === rec ? ' rec' : '') + '" data-set-variant="' + s + '" title="' + (s === rec ? 'Recommended' : '') + '">' + esc(b.dataset.screen || '') + '/' + s + '</button>').join('') + '</span>';
    if (b.dataset.shell !== 'plain') h += '<span class="grp"><span>Drive</span><button class="rb" data-drive="on">Connected</button><button class="rb" data-drive="off">Not connected</button></span>';
    h += '<span style="flex:1"></span><button class="rb" data-act="annotate">Annotate<kbd>A</kbd></button><button class="rb" data-act="comment">Comment<kbd>C</kbd></button><button class="rb" data-act="notes">Notes <span data-note-count></span><kbd>N</kbd></button><button class="rb" data-act="theme">Dark</button></div>';
    b.insertBefore(el(h), b.firstChild);
    setTheme(store.get('mlm-b1-theme', matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
    if (states.length) setAttrState('state', states[0]);
    if (vars.length) setAttrState('variant', rec);
    setDrive(store.get('mlm-b1-drive', 'on') !== 'off' || b.dataset.shell === 'plain');
    const hv = decodeURIComponent(location.hash.slice(1)); if (hv) goto(hv);
  }
  function goto(name) {
    const target = $('[data-view="' + name + '"]'); if (!target) return false;
    const grp = target.dataset.viewGroup || '';
    $$('[data-view]').forEach(v => { if ((v.dataset.viewGroup || '') === grp) v.hidden = v !== target; });
    $$('[data-goto]').forEach(g => g.classList.toggle('on', g.dataset.goto === name && g.classList.contains('scope') || g.dataset.goto === name && g.parentElement.classList.contains('seg')));
    document.dispatchEvent(new CustomEvent('mlm:view', { detail: name })); refreshBadges(); return true;
  }

  /* ───────── Menus, popovers, sheets ───────── */
  function closeMenus() { $$('.menu.open,.popover.open').forEach(m => { m.classList.remove('open'); m.hidden = true; }); }
  function place(m, x, y) { m.hidden = false; m.classList.add('open'); m.style.position = 'fixed'; const r = m.getBoundingClientRect(); m.style.left = Math.max(6, Math.min(x, innerWidth - r.width - 6)) + 'px'; m.style.top = Math.max(6, Math.min(y, innerHeight - r.height - 6)) + 'px'; refreshBadges(); }
  function openMenu(id, x, y, ctx) {
    const m = document.getElementById(id); if (!m) return; closeMenus();
    const c = $('[data-cm-count]', m); if (c) { const n = ctx && ctx.rows ? ctx.rows.length : 1; c.hidden = n < 2; c.textContent = n + ' tracks'; }
    place(m, x, y);
  }
  function openSheet(id, from) {
    const s = document.getElementById(id); if (!s) return;
    const win = (from && from.closest('.window')) || shell.win || $('.window'); if (!win || !win.classList || !win.classList.contains('window')) { s.hidden = false; return; }
    let scrim = $(':scope > .scrim', win); if (!scrim) { scrim = el('<div class="scrim"></div>'); win.appendChild(scrim); }
    $$(':scope > *', scrim).forEach(n => { n.hidden = true; document.getElementById('overlays').appendChild(n); });
    scrim.appendChild(s); s.hidden = false; refreshBadges();
  }
  function closeSheet(node) { const scrim = node.closest('.scrim'); const s = node.closest('.sheet,.alert'); if (s && !s.classList.contains('static')) { s.hidden = true; (document.getElementById('overlays') || document.body).appendChild(s); } if (scrim) scrim.remove(); refreshBadges(); }

  /* ───────── Annotate mode ───────── */
  let annoLayer = null, annoTip = null, badgeTimer = 0;
  const notes = () => store.get(FBKEY + PAGE, { notes: {} });
  function refreshBadges() { clearTimeout(badgeTimer); badgeTimer = setTimeout(drawBadges, 60); }
  function drawBadges() {
    if (annoLayer) annoLayer.remove(); annoLayer = null;
    const nn = notes().notes; const cnt = Object.keys(nn).length; $$('[data-note-count]').forEach(x => x.textContent = cnt ? '(' + cnt + ')' : '');
    const on = document.body.classList.contains('annotate'), com = document.body.classList.contains('commenting'); if (!on && !com) return;
    annoLayer = el('<div class="anno-layer"></div>'); document.body.appendChild(annoLayer);
    const sx = scrollX, sy = scrollY; let html = '';
    $$('[data-fb-id]').forEach(n => {
      if (n.closest('[hidden]') || n.closest('.reviewbar')) return; const r = n.getBoundingClientRect(); if (!r.width && !r.height) return; if (r.bottom < -40 || r.top > innerHeight + 2000) return;
      const has = nn[n.dataset.fbId]; if (!on && !has) return;
      html += '<span class="anno-badge' + (has ? ' has-note' : '') + '" style="left:' + (r.left + sx + 2) + 'px;top:' + (r.top + sy + 4) + 'px">' + esc(n.dataset.fbId) + (has ? ' ✎' : '') + '</span>';
    });
    annoLayer.innerHTML = html;
  }
  function showTip(n, e) {
    hideTip(); const d = n.dataset; const has = notes().notes[d.fbId];
    annoTip = el('<div class="anno-tip"><b>' + esc(d.fbId) + '</b>' + esc(d.fbLabel || '') + (d.fbNote ? '<div>' + esc(d.fbNote) + '</div>' : '') + '<div class="meta">' + (d.fbDec ? '→ ' + esc(d.fbDec) + ' (THOUGHTS.md §8) ' : '') + (d.fbApi ? '· <code>' + esc(d.fbApi) + '</code>' : '') + '</div>' + (has ? '<div class="meta">✎ ' + esc(has.text) + '</div>' : '') + '</div>');
    document.body.appendChild(annoTip); const r = annoTip.getBoundingClientRect(); annoTip.style.left = Math.min(e.clientX + 14, innerWidth - r.width - 8) + 'px'; annoTip.style.top = Math.min(e.clientY + 16, innerHeight - r.height - 8) + 'px';
  }
  function hideTip() { if (annoTip) annoTip.remove(); annoTip = null; }

  /* ───────── Comment mode & export ───────── */
  const SCREENS = { 'W-MAIN': 'Main window', 'P-SIDEBAR': 'Sidebar', 'P-PINNED': 'Playlists in the sidebar', 'P-TOOLBAR': 'Toolbar', 'P-PLAYER': 'Player', 'P-PREVIEW': 'Space-bar preview', 'P-QUEUE': 'Queue', 'V-QUEUE': 'Queue', 'P-INSPECTOR': 'Track inspector', 'P-ACTIVITY': 'Activity', 'P-ACTIVITY-OPS': 'Activity — operations', 'P-ACTIVITY-LOGS': 'Activity — logs', 'W-ACTIVITY': 'Activity window', 'P-SELBAR': 'Selection bar', 'P-STATUSBAR': 'Status bar', 'P-LIBFOOTER': 'Library footer', 'P-ADDMENU': 'Add menu', 'V-LIB': 'All Tracks', 'V-TRACK-TABLE': 'Track table', 'V-TRACK-PRIMITIVES': 'Track primitives', 'CM-TRACK': 'Track context menu', 'V-ALB': 'Albums', 'V-ALBD': 'Album detail', 'V-GENRES': 'Genres', 'V-GENRED': 'Genre detail', 'V-FOLD': 'Folders', 'V-PL': 'All Playlists', 'V-PLD': 'Playlist detail', 'V-SEARCH': 'Search', 'S-QUICKADD': 'Add from link', 'S-IMPORT': 'Import playlist from source', 'V-SRC': 'Sources', 'W-REMOTE': 'Remote import', 'V-REV': 'Review', 'V-DISC': 'Discover', 'V-INBOX': 'Recommendations', 'V-REELS': 'Reels', 'V-SIMILAR': 'Similar tracks', 'V-SYNC': 'Sync profiles', 'V-SYNC-DETAIL': 'Sync profile', 'W-SETTINGS': 'Settings', 'V-PICKER': 'Library picker', 'V-SETUP': 'First-run setup', 'G-DRIVE-OFFLINE': 'Drive not connected', 'ICON-MLIBM': 'Library-file icon' };
  function screenOf(id) { return id.split('.')[0].split('/')[0]; }
  function editNote(n, e) {
    $$('.fb-editor').forEach(x => x.remove()); const d = n.dataset, st = notes(), cur = st.notes[d.fbId];
    const ed = el('<div class="fb-editor"><b>' + esc(d.fbId) + '</b><span class="caption">' + esc(d.fbLabel || '') + '</span><textarea placeholder="Your note on this element…"></textarea><div class="row"><button class="btn" data-x="del">Delete</button><span class="grow"></span><button class="btn" data-x="cancel">Cancel</button><button class="btn primary" data-x="save">Save</button></div></div>');
    document.body.appendChild(ed); const ta = $('textarea', ed); ta.value = cur ? cur.text : ''; const r = ed.getBoundingClientRect(); ed.style.left = Math.max(8, Math.min(e.clientX, innerWidth - r.width - 8)) + 'px'; ed.style.top = Math.max(8, Math.min(e.clientY + 10, innerHeight - r.height - 8)) + 'px'; ta.focus();
    const save = () => { const s = notes(); const v = ta.value.trim(); if (v) s.notes[d.fbId] = { text: v, label: d.fbLabel || '', variant: document.body.dataset.variant || '', state: document.body.dataset.state || '', ts: Date.now() }; else delete s.notes[d.fbId]; s.title = document.body.dataset.title || document.title; s.screen = document.body.dataset.screen || ''; store.set(FBKEY + PAGE, s); ed.remove(); refreshBadges(); renderPanel(); };
    ed.addEventListener('click', ev => { const x = ev.target.dataset.x; if (x === 'save') save(); else if (x === 'cancel') ed.remove(); else if (x === 'del') { ta.value = ''; save(); } });
    ta.addEventListener('keydown', ev => { if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) save(); if (ev.key === 'Escape') ed.remove(); ev.stopPropagation(); });
  }
  function pageMarkdown(page, s) {
    const groups = {}; Object.keys(s.notes).sort().forEach(id => { (groups[screenOf(id)] = groups[screenOf(id)] || []).push(id); });
    let md = ''; Object.keys(groups).forEach(g => {
      md += '### ' + g + ' — ' + (SCREENS[g] || s.title || page) + '\n';
      groups[g].forEach(id => { const n = s.notes[id]; const ctx = [n.variant ? 'variant ' + (s.screen || g) + '/' + n.variant : '', n.state && n.state !== 'default' ? 'state ' + n.state : ''].filter(Boolean).join(', '); md += '- ' + id + (n.label ? ' (' + n.label + ')' : '') + (ctx ? ' [' + ctx + ']' : '') + ': ' + n.text.replace(/\n+/g, ' / ') + '\n'; });
      md += '\n';
    }); return md;
  }
  function exportMarkdown(all) {
    let md = '# MLM B1 feedback\n\nExported ' + new Date().toISOString().slice(0, 16).replace('T', ' ') + '\n\n', n = 0;
    const keys = all ? Object.keys(localStorage).filter(k => k.indexOf(FBKEY) === 0).sort() : [FBKEY + PAGE];
    keys.forEach(k => { const s = store.get(k, { notes: {} }); const c = Object.keys(s.notes || {}).length; if (!c) return; n += c; const pg = k.slice(FBKEY.length); md += '## ' + pg + '.html' + (s.title ? ' — ' + s.title : '') + '\n\n' + pageMarkdown(pg, s); });
    if (!n) { toast('No notes yet. Press C, then click an element.'); return ''; }
    const done = () => toast(n + ' note' + (n === 1 ? '' : 's') + ' copied to the clipboard and downloaded as Markdown.');
    try { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([md], { type: 'text/markdown' })); a.download = 'mlm-b1-feedback' + (all ? '' : '-' + PAGE) + '.md'; document.body.appendChild(a); a.click(); a.remove(); } catch (e) { /* ignore */ }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(md).then(done, done); else done();
    return md;
  }
  function toast(t) { $$('.fb-toast').forEach(x => x.remove()); const n = el('<div class="fb-toast"></div>'); n.textContent = t; document.body.appendChild(n); setTimeout(() => n.remove(), 3200); }
  function renderPanel() {
    const p = $('.fb-panel'); if (!p) return; const s = notes(), ids = Object.keys(s.notes).sort();
    $('.list', p).innerHTML = ids.length ? ids.map(id => '<div class="it"><span class="x" data-del="' + esc(id) + '">✕</span><code>' + esc(id) + '</code> <span class="caption">' + esc(s.notes[id].label || '') + '</span><p>' + esc(s.notes[id].text) + '</p></div>').join('') : '<p class="caption">No notes on this page yet. Press <b>C</b>, then click any element.</p>';
  }
  function togglePanel() {
    const p = $('.fb-panel'); if (p) { p.remove(); return; }
    const n = el('<div class="fb-panel"><header><b>Notes on this page</b><button class="btn" data-x="export">Export feedback</button><button class="btn" data-x="close">✕</button></header><div class="list"></div></div>');
    document.body.appendChild(n); renderPanel();
    n.addEventListener('click', e => { const t = e.target; if (t.dataset.x === 'export') exportMarkdown(false); else if (t.dataset.x === 'close') n.remove(); else if (t.dataset.del) { const s = notes(); delete s.notes[t.dataset.del]; store.set(FBKEY + PAGE, s); renderPanel(); refreshBadges(); } });
  }
  function toggleMode(m) { const b = document.body; if (m === 'annotate') b.classList.toggle('annotate'); else { b.classList.toggle('commenting'); } $$('.reviewbar [data-act="annotate"]').forEach(x => x.classList.toggle('on', b.classList.contains('annotate'))); $$('.reviewbar [data-act="comment"]').forEach(x => x.classList.toggle('on', b.classList.contains('commenting'))); hideTip(); refreshBadges(); }

  /* ───────── Global events ───────── */
  function wire() {
    document.addEventListener('click', e => {
      const t = e.target;
      if (document.body.classList.contains('commenting') && !t.closest('.reviewbar,.fb-editor,.fb-panel')) { const n = t.closest('[data-fb-id]'); if (n) { e.preventDefault(); e.stopPropagation(); editNote(n, e); } return; }
      const a = t.closest('[data-act],[data-set-state],[data-set-variant],button[data-drive],[data-drive-on],[data-goto],[data-open],[data-close],[data-menu-click],[data-popover],[data-say],.seg button,.scope,.check,.toggle,.radio');
      const inMenu = t.closest('.menu,.popover');
      if (!a) { if (!inMenu) closeMenus(); else if (t.closest('.mi')) closeMenus(); return; }
      const d = a.dataset;
      if (d.setState) { if ('close' in d) closeSheet(a); return setAttrState('state', d.setState); }
      if (d.setVariant) return setAttrState('variant', d.setVariant);
      if (d.drive) return setDrive(d.drive === 'on');
      if ('driveOn' in d) { setDrive(true); shell.say('“Lexxar” connected.'); return; }
      if (d.act === 'annotate' || d.act === 'comment') return toggleMode(d.act);
      if (d.act === 'notes') return togglePanel();
      if (d.act === 'theme') return setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
      if (d.act === 'export-all') return exportMarkdown(true);
      if (d.act === 'sidebar') { shell.win.classList.toggle('no-sidebar'); return refreshBadges(); }
      if (d.act === 'back') { if (!goto(document.body.dataset.home || '')) history.back(); return; }
      if (d.act === 'info' || d.act === 'queue' || d.act === 'info-open') { const tr = $('.trailing', shell.win); if (!tr) return; const want = d.act === 'queue' ? 'queue' : 'info'; const cur = $('.seg[data-group="trail"] .on', tr).dataset.p; if (!tr.hidden && cur === want && d.act !== 'info-open') tr.hidden = true; else { tr.hidden = false; $('.seg[data-group="trail"] [data-p="' + want + '"]', tr).click(); } closeMenus(); return refreshBadges(); }
      if (d.act === 'playpause') { if (shell.previewing) shell.endPreview(); return; }
      if (d.say) { const n = (tables[0] ? tables[0].selection().length : 0) || 1; shell.say(d.say.replace('{n}', n), true); if (inMenu) closeMenus(); return; }
      if ('close' in d) { closeSheet(a); if (!d.open && !d.goto) return; }
      if (d.open) { closeMenus(); openSheet(d.open, a); if (!d.goto) return; }
      if (d.goto) { if (inMenu) closeMenus(); goto(d.goto); return; }
      if (d.menuClick) { e.preventDefault(); const r = a.getBoundingClientRect(); const up = a.classList.contains('sb-foot'); openMenu(d.menuClick, r.left, up ? r.top - 190 : r.bottom + 4, { rows: tables[0] ? tables[0].selection() : [] }); return; }
      if (d.popover) { const p = document.getElementById(d.popover); if (!p) return; const was = p.classList.contains('open'); closeMenus(); if (!was) { const r = a.getBoundingClientRect(); place(p, r.left + r.width / 2 - 170, r.bottom + 8); } return; }
      if (a.matches('.seg button')) { const seg = a.parentElement; $$('button', seg).forEach(x => x.classList.toggle('on', x === a)); const g = seg.dataset.group; if (g) $$('[data-pane^="' + g + ':"]').forEach(p => { p.hidden = p.dataset.pane !== g + ':' + a.dataset.p; }); return refreshBadges(); }
      if (a.matches('.scope')) { $$('.scope', a.parentElement).forEach(x => x.classList.toggle('on', x === a)); if ('statusFilter' in d && tables[0]) { const f = d.statusFilter; tables[0].setFilter(f ? (t => f.split(',').includes(t.status)) : null); } a.dispatchEvent(new CustomEvent('mlm:scope', { bubbles: true, detail: d.scope || d.statusFilter || '' })); return; }
      if (a.matches('.check:not(.radio),.toggle')) { a.classList.toggle('on'); return; }
      if (a.matches('.radio')) { $$('.radio', a.parentElement.parentElement).forEach(x => { if (x.dataset.name === a.dataset.name) x.classList.remove('on'); }); a.classList.add('on'); return; }
    }, true);
    document.addEventListener('contextmenu', e => { const m = e.target.closest('[data-menu]'); if (m && !e.target.closest('.table tbody tr, .table th')) { e.preventDefault(); openMenu(m.dataset.menu, e.clientX, e.clientY); } });
    document.addEventListener('mouseover', e => { if (!document.body.classList.contains('annotate')) return; const n = e.target.closest('[data-fb-id]'); if (n) showTip(n, e); else hideTip(); });
    document.addEventListener('keydown', e => {
      const typing = /INPUT|TEXTAREA|SELECT/.test(e.target.tagName);
      if (e.key === 'Escape') { closeMenus(); $$('.fb-editor').forEach(x => x.remove()); const s = $('.scrim .sheet, .scrim .alert'); if (s) closeSheet(s); return; }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'i' && !e.shiftKey) { const x = $('[data-act="info"]'); if (x) { e.preventDefault(); x.click(); } return; }
      if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
      const k = e.key.toLowerCase();
      if (k === 'a') toggleMode('annotate'); else if (k === 'c') toggleMode('comment'); else if (k === 'n') togglePanel();
    });
    document.addEventListener('mlm:select', e => {
      const rows = e.detail.rows, win = shell.win; if (!win || !win.querySelector) return;
      const sb = $('.selbar', win); if (sb) { sb.hidden = rows.length < 2; $('.cnt', sb).innerHTML = rows.length + ' selected<small>' + fmtDur(rows.reduce((a, r) => a + r.time, 0)) + '</small>'; }
      const def = $('.statusbar .def', win); if (def && e.detail.table === tables[0]) { const tot = e.detail.total; def.innerHTML = rows.length ? rows.length + ' of ' + tot.length.toLocaleString('en-US') + ' selected · ' + fmtDur(rows.reduce((a, r) => a + r.time, 0)) : (document.body.dataset.status || tot.length.toLocaleString('en-US') + ' tracks · ' + fmtDur(tot.reduce((a, r) => a + r.time, 0))); }
      inspectorAuto(rows); refreshBadges();
    });
    document.addEventListener('input', e => { if (e.target.classList.contains('search') && tables[0] && !document.body.dataset.searchManual) { const q = e.target.value.toLowerCase().split(/\s+/).filter(Boolean); tables[0].setFilter(q.length ? (t => q.every(w => (t.title + ' ' + t.artist + ' ' + t.album + ' ' + t.genre).toLowerCase().includes(w))) : null); } });
    addEventListener('resize', refreshBadges); document.addEventListener('scroll', refreshBadges, true);
  }

  window.MLM = { setState: v => setAttrState('state', v), setVariant: v => setAttrState('variant', v), icon, tracks, table, shell, fmtTime, fmtDur, STATUS, COLS, esc, el, goto, openSheet, openMenu, exportMarkdown, say: (h, u) => shell.say(h, u), hydrateIcons, refreshBadges, tables };
  function init() { hydrateIcons(document); buildShell(); hydrateIcons(document); wire(); document.dispatchEvent(new CustomEvent('mlm:ready')); refreshBadges(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
