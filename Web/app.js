'use strict';

const REFRESH_INTERVAL_MS = 2500;

const state = {
    sessions: [],
    selectedName: null,
    socket: null,
    term: null,
    fitAddon: null,
    encoder: new TextEncoder(),
    refreshTimer: null,
    searchQuery: '',
};

// ---------- DOM ----------
const sidebarEl = document.getElementById('sidebar');
const sessionListEl = document.getElementById('session-list');
const searchEl = document.getElementById('search');
const refreshButton = document.getElementById('refresh-button');
const reconnectButton = document.getElementById('reconnect-button');
const sidebarToggle = document.getElementById('sidebar-toggle');
const sessionTitleEl = document.getElementById('session-title');
const terminalEl = document.getElementById('terminal');
const placeholderEl = document.getElementById('terminal-placeholder');
const statusIndicator = document.getElementById('status-indicator');
const keybarEl = document.getElementById('keybar');

// ---------- session list ----------
async function fetchSessions() {
    try {
        const resp = await fetch('/api/sessions', { cache: 'no-store' });
        if (!resp.ok) {
            throw new Error(`HTTP ${resp.status}`);
        }
        state.sessions = await resp.json();
        statusIndicator.textContent = `${state.sessions.length} session${state.sessions.length === 1 ? '' : 's'}`;
        renderSessionList();
    } catch (err) {
        statusIndicator.textContent = `error: ${err.message}`;
    }
}

function renderSessionList() {
    const query = state.searchQuery.toLowerCase().trim();
    const filtered = query
        ? state.sessions.filter(s => sessionMatches(s, query))
        : state.sessions;

    const groups = groupByRepo(filtered);
    sessionListEl.innerHTML = '';

    for (const group of groups) {
        const groupEl = document.createElement('div');
        groupEl.className = 'session-group';

        const nameEl = document.createElement('div');
        nameEl.className = 'session-group-name';
        nameEl.textContent = group.name;
        groupEl.appendChild(nameEl);

        for (const session of group.sessions) {
            groupEl.appendChild(renderSessionItem(session));
        }
        sessionListEl.appendChild(groupEl);
    }
}

function renderSessionItem(session) {
    const item = document.createElement('div');
    item.className = 'session-item';
    item.dataset.name = session.name;
    if (session.name === state.selectedName) {
        item.classList.add('selected');
    }
    item.role = 'listitem';

    const dot = document.createElement('span');
    const status = session.metadata?.status || 'unknown';
    dot.className = `session-status-dot ${status}`;
    item.appendChild(dot);

    const body = document.createElement('div');
    body.className = 'session-body';

    const name = document.createElement('div');
    name.className = 'session-name';
    name.textContent = session.name;
    body.appendChild(name);

    const detail = document.createElement('div');
    detail.className = 'session-detail';
    detail.textContent = sessionDetailText(session);
    body.appendChild(detail);

    item.appendChild(body);

    item.addEventListener('click', () => {
        attachSession(session.name);
        if (window.matchMedia('(max-width: 768px)').matches) {
            sidebarEl.classList.remove('open');
        }
    });

    return item;
}

function sessionDetailText(session) {
    return session.metadata?.desc
        || session.metadata?.task
        || session.metadata?.branch
        || session.process
        || session.working_dir
        || '';
}

function sessionMatches(session, query) {
    const haystack = [
        session.name,
        session.process,
        session.working_dir,
        session.metadata?.repo,
        session.metadata?.task,
        session.metadata?.branch,
        session.metadata?.desc,
    ].filter(Boolean).join(' ').toLowerCase();
    return haystack.includes(query);
}

function groupByRepo(sessions) {
    const map = new Map();
    for (const s of sessions) {
        const key = s.metadata?.repo || inferRepoFromPath(s.working_dir) || 'Ungrouped';
        if (!map.has(key)) map.set(key, []);
        map.get(key).push(s);
    }
    const names = [...map.keys()].sort((a, b) => {
        if (a === 'Ungrouped') return 1;
        if (b === 'Ungrouped') return -1;
        return a.localeCompare(b);
    });
    return names.map(name => ({ name, sessions: map.get(name) }));
}

function inferRepoFromPath(path) {
    if (!path) return null;
    const parts = path.split('/').filter(Boolean);
    return parts[parts.length - 1] || null;
}

// ---------- terminal ----------
function ensureTerminal() {
    if (state.term) return state.term;
    const term = new Terminal({
        cursorBlink: true,
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, monospace',
        fontSize: 13,
        theme: {
            background: '#000000',
            foreground: '#e6e8eb',
            cursor: '#5cc7a0',
        },
        scrollback: 5000,
        allowProposedApi: true,
    });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(terminalEl);
    fit.fit();
    state.term = term;
    state.fitAddon = fit;

    // Forward keystrokes as binary bytes.
    term.onData(data => {
        if (state.socket && state.socket.readyState === WebSocket.OPEN) {
            state.socket.send(state.encoder.encode(data));
        }
    });

    window.addEventListener('resize', () => {
        try { fit.fit(); } catch (_) {}
        sendResize();
    });
    return term;
}

function sendResize() {
    if (!state.term || !state.socket || state.socket.readyState !== WebSocket.OPEN) {
        return;
    }
    state.socket.send(JSON.stringify({
        type: 'resize',
        rows: state.term.rows,
        cols: state.term.cols,
    }));
}

function attachSession(name) {
    if (state.selectedName === name && state.socket && state.socket.readyState === WebSocket.OPEN) {
        return;
    }
    state.selectedName = name;
    sessionTitleEl.textContent = name;
    placeholderEl.classList.add('hidden');
    document.querySelectorAll('.session-item').forEach(el => {
        el.classList.toggle('selected', el.dataset.name === name);
    });

    closeSocket();

    const term = ensureTerminal();
    term.reset();
    state.fitAddon.fit();

    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = `${proto}//${location.host}/ws/sessions/${encodeURIComponent(name)}`;
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    state.socket = ws;

    ws.addEventListener('open', () => {
        sendResize();
        term.focus();
    });

    ws.addEventListener('message', (ev) => {
        if (typeof ev.data === 'string') {
            // Server only sends binary for output; ignore text.
            return;
        }
        term.write(new Uint8Array(ev.data));
    });

    ws.addEventListener('close', () => {
        if (state.socket === ws) {
            state.socket = null;
        }
    });

    ws.addEventListener('error', () => {
        // close handler runs after this
    });
}

function closeSocket() {
    if (state.socket) {
        try { state.socket.close(); } catch (_) {}
        state.socket = null;
    }
}

// ---------- keybar ----------
function setupKeybar() {
    keybarEl.addEventListener('click', (ev) => {
        const btn = ev.target.closest('button');
        if (!btn || !state.socket || state.socket.readyState !== WebSocket.OPEN) return;

        if (btn.dataset.text) {
            state.socket.send(state.encoder.encode(btn.dataset.text));
        } else if (btn.dataset.ctrl) {
            const ch = btn.dataset.ctrl.toLowerCase();
            const code = ch.charCodeAt(0) - 96; // 'a' → 1
            if (code >= 1 && code <= 26) {
                state.socket.send(new Uint8Array([code]));
            }
        } else if (btn.dataset.key) {
            const seq = keyToSequence(btn.dataset.key);
            if (seq) state.socket.send(state.encoder.encode(seq));
        }
        if (state.term) state.term.focus();
    });
}

function keyToSequence(key) {
    switch (key) {
        case 'Escape': return '\x1b';
        case 'Tab': return '\t';
        case 'ArrowUp': return '\x1b[A';
        case 'ArrowDown': return '\x1b[B';
        case 'ArrowRight': return '\x1b[C';
        case 'ArrowLeft': return '\x1b[D';
        default: return null;
    }
}

// ---------- events ----------
refreshButton.addEventListener('click', fetchSessions);
reconnectButton.addEventListener('click', () => {
    if (state.selectedName) attachSession(state.selectedName);
});
sidebarToggle.addEventListener('click', () => {
    sidebarEl.classList.toggle('open');
});
searchEl.addEventListener('input', (ev) => {
    state.searchQuery = ev.target.value;
    renderSessionList();
});

// ---------- service worker ----------
if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
        navigator.serviceWorker.register('/sw.js').catch(() => {});
    });
}

// ---------- bootstrap ----------
fetchSessions();
state.refreshTimer = setInterval(fetchSessions, REFRESH_INTERVAL_MS);
setupKeybar();
