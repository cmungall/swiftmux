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
    token: null,
    viewMode: localStorage.getItem('swiftmux.viewMode') || 'recent',
    orderMode: localStorage.getItem('swiftmux.orderMode') || 'activity',
};

// ---------- DOM ----------
const sidebarEl = document.getElementById('sidebar');
const sessionListEl = document.getElementById('session-list');
const searchEl = document.getElementById('search');
const refreshButton = document.getElementById('refresh-button');
const reconnectButton = document.getElementById('reconnect-button');
const sidebarToggle = document.getElementById('sidebar-toggle');
const sessionTitleEl = document.getElementById('session-title');
const sessionPathEl = document.getElementById('session-path');
const topbarChipsEl = document.getElementById('topbar-chips');
const terminalEl = document.getElementById('terminal');
const placeholderEl = document.getElementById('terminal-placeholder');
const statusIndicator = document.getElementById('status-indicator');
const keybarEl = document.getElementById('keybar');
const viewModeButtons = document.querySelectorAll('[data-view-mode]');
const orderModeButtons = document.querySelectorAll('[data-order-mode]');

function loadToken() {
    const params = new URLSearchParams(location.search);
    const token = params.get('token') || localStorage.getItem('swiftmux.token');
    if (token) {
        localStorage.setItem('swiftmux.token', token);
        state.token = token;
    }
}

function apiFetchOptions() {
    const headers = {};
    if (state.token) {
        headers.Authorization = `Bearer ${state.token}`;
    }
    return { cache: 'no-store', headers };
}

function tokenQuery() {
    return state.token ? `?token=${encodeURIComponent(state.token)}` : '';
}

// ---------- session list ----------
async function fetchSessions() {
    try {
        const resp = await fetch('/api/sessions', apiFetchOptions());
        if (!resp.ok) {
            throw new Error(`HTTP ${resp.status}`);
        }
        state.sessions = await resp.json();
        statusIndicator.textContent = `${state.sessions.length} session${state.sessions.length === 1 ? '' : 's'}`;
        renderSessionList();
        renderSelectedSessionSummary();
    } catch (err) {
        statusIndicator.textContent = `error: ${err.message}`;
    }
}

function renderSessionList() {
    const query = state.searchQuery.toLowerCase().trim();
    const filtered = query
        ? state.sessions.filter(s => sessionMatches(s, query))
        : state.sessions;

    sessionListEl.innerHTML = '';

    if (state.viewMode === 'recent') {
        for (const session of sortSessions(filtered)) {
            sessionListEl.appendChild(renderSessionItem(session, repoGroupName(session), repoRootPath(session)));
        }
        return;
    }

    const groups = groupByRepo(filtered);
    for (const group of groups) {
        const sectionEl = document.createElement('section');
        sectionEl.className = 'session-group';

        const headerEl = document.createElement('div');
        headerEl.className = 'session-group-name';

        const labelEl = document.createElement('span');
        labelEl.textContent = group.name;
        headerEl.appendChild(labelEl);

        const countEl = document.createElement('span');
        countEl.className = 'session-group-count';
        countEl.textContent = `${group.sessions.length}`;
        headerEl.appendChild(countEl);

        sectionEl.appendChild(headerEl);

        for (const session of group.sessions) {
            sectionEl.appendChild(renderSessionItem(session, repoScopedLocationName(session), session.working_dir));
        }
        sessionListEl.appendChild(sectionEl);
    }
}

function renderSessionItem(session, contextLabel, contextHelp) {
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

    const meta = document.createElement('div');
    meta.className = 'session-meta';
    appendPlainMeta(meta, contextLabel, contextHelp);
    appendPlainMeta(meta, session.metadata?.branch);
    if (pullRequestSummary(session)) {
        meta.appendChild(createChip(`PR ${pullRequestSummary(session)}`, `pr ${pullRequestTone(session)}`, pullRequestHelpText(session)));
    }
    meta.appendChild(createChip(statusLabel(session), `status ${statusClass(session)}`));
    if (activityDate(session)) {
        meta.appendChild(createChip(activityLabel(session), `activity ${activityBucket(session)}`, activityHelpText(session)));
    }
    body.appendChild(meta);

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
        || shortenedWorkingDirectory(session.working_dir)
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
        session.metadata?.pr,
        session.metadata?.pr_state,
        session.metadata?.pr_review,
        session.metadata?.pr_merge_state,
    ].filter(Boolean).join(' ').toLowerCase();
    return fuzzyMatch(query, haystack);
}

function groupByRepo(sessions) {
    const map = new Map();
    for (const s of sessions) {
        const key = repoGroupKey(s);
        if (!map.has(key)) {
            map.set(key, {
                name: repoGroupName(s),
                sessions: [],
                activityAt: null,
            });
        }
        const group = map.get(key);
        group.sessions.push(s);
        const activity = activityDate(s);
        if (activity && (!group.activityAt || activity > group.activityAt)) {
            group.activityAt = activity;
        }
    }

    return [...map.values()].map(group => ({
        ...group,
        sessions: sortSessions(group.sessions),
    })).sort((a, b) => {
        if (state.orderMode === 'activity' && Number(a.activityAt) !== Number(b.activityAt)) {
            return Number(b.activityAt || 0) - Number(a.activityAt || 0);
        }
        if (a.name === 'Ungrouped') return 1;
        if (b.name === 'Ungrouped') return -1;
        return a.name.localeCompare(b.name);
    });
}

function sortSessions(sessions) {
    return [...sessions].sort(compareSessions);
}

function compareSessions(a, b) {
    if (state.orderMode === 'activity') {
        const activityDelta = Number(activityDate(b) || 0) - Number(activityDate(a) || 0);
        if (activityDelta !== 0) return activityDelta;
    }

    const repoDelta = repoGroupName(a).localeCompare(repoGroupName(b));
    if (repoDelta !== 0) return repoDelta;

    const statusDelta = statusRank(a) - statusRank(b);
    if (statusDelta !== 0) return statusDelta;

    return a.name.localeCompare(b.name);
}

function renderSelectedSessionSummary() {
    const session = selectedSession();
    topbarChipsEl.innerHTML = '';

    if (!session) {
        sessionTitleEl.textContent = 'No session';
        sessionPathEl.textContent = '';
        return;
    }

    sessionTitleEl.textContent = session.name;
    topbarChipsEl.appendChild(createChip(statusLabel(session), `status ${statusClass(session)}`));
    if (activityDate(session)) {
        topbarChipsEl.appendChild(createChip(activityLabel(session), `activity ${activityBucket(session)}`, activityHelpText(session)));
    }
    topbarChipsEl.appendChild(createChip(session.process, 'plain'));
    if (session.metadata?.branch) {
        topbarChipsEl.appendChild(createChip(session.metadata.branch, 'plain'));
    }
    if (pullRequestSummary(session)) {
        topbarChipsEl.appendChild(createChip(`PR ${pullRequestSummary(session)}`, `pr ${pullRequestTone(session)}`, pullRequestHelpText(session)));
    }

    const path = session.working_dir || '';
    const repo = repoRootPath(session);
    sessionPathEl.textContent = repo && repo !== path
        ? `${shortenedWorkingDirectory(path)} · ${repoGroupName(session)}`
        : shortenedWorkingDirectory(path);
}

function selectedSession() {
    return state.sessions.find(s => s.name === state.selectedName) || null;
}

function appendPlainMeta(parent, text, title) {
    if (!text) return;
    const span = document.createElement('span');
    span.className = 'plain-meta';
    span.textContent = text;
    if (title) span.title = title;
    parent.appendChild(span);
}

function createChip(text, className = 'plain', title) {
    const span = document.createElement('span');
    span.className = `metadata-chip ${className}`;
    span.textContent = text;
    if (title) span.title = title;
    return span;
}

function fuzzyMatch(query, text) {
    if (!query) return true;
    let index = 0;
    for (const char of text.toLowerCase()) {
        if (char === query[index]) {
            index += 1;
            if (index === query.length) return true;
        }
    }
    return false;
}

function repoRootPath(session) {
    const repo = session.canonical_repo_root || session.metadata?.repo;
    if (!repo) return null;
    return repo.startsWith('/') || repo.startsWith('~') ? repo : null;
}

function repoGroupName(session) {
    const repo = repoRootPath(session) || session.metadata?.repo;
    if (repo) {
        return lastPathComponent(repo) || repo;
    }
    return folderGroupName(session) || 'Ungrouped';
}

function repoGroupKey(session) {
    return repoRootPath(session) || `repo:${repoGroupName(session).toLowerCase()}`;
}

function folderGroupName(session) {
    return lastPathComponent(session.working_dir) || 'Ungrouped';
}

function repoScopedLocationName(session) {
    const repo = repoRootPath(session);
    const workingDir = session.working_dir;
    if (!repo || !workingDir) return folderGroupName(session);
    if (normalizePath(repo) === normalizePath(workingDir)) return 'root';
    return folderGroupName(session);
}

function lastPathComponent(path) {
    if (!path) return null;
    const parts = path.split('/').filter(Boolean);
    return parts[parts.length - 1] || null;
}

function normalizePath(path) {
    return (path || '').replace(/\/+$/, '');
}

function shortenedWorkingDirectory(path) {
    if (!path) return '';
    const home = localStorage.getItem('swiftmux.homePrefix');
    if (home && path.startsWith(home)) {
        return `~${path.slice(home.length)}`;
    }
    const match = path.match(/^\/Users\/([^/]+)(.*)$/);
    return match ? `~${match[2]}` : path;
}

function statusLabel(session) {
    switch (session.metadata?.status) {
        case 'active': return 'Active';
        case 'idle': return 'Idle';
        case 'done': return 'Done';
        case 'waiting-human': return 'Waiting Human';
        default: return 'Unknown';
    }
}

function statusClass(session) {
    return ['active', 'idle', 'done', 'waiting-human'].includes(session.metadata?.status)
        ? session.metadata.status
        : 'unknown';
}

function statusRank(session) {
    switch (session.metadata?.status) {
        case 'active': return 0;
        case 'waiting-human': return 1;
        case 'idle': return 2;
        case 'done': return 3;
        default: return 4;
    }
}

function parseTimestamp(value) {
    if (!value) return null;
    const time = Date.parse(value);
    return Number.isNaN(time) ? null : new Date(time);
}

function activityDate(session) {
    return parseTimestamp(session.tmux_activity_at)
        || parseTimestamp(session.metadata?.last_send)
        || parseTimestamp(session.metadata?.last_refresh);
}

function activityBucket(session) {
    const date = activityDate(session);
    if (!date) return 'none';
    const age = Math.max((Date.now() - date.getTime()) / 1000, 0);
    if (age < 60) return 'seconds';
    if (age < 3600) return 'minutes';
    if (age < 86400) return 'hours';
    if (age < 2592000) return 'days';
    if (age < 31557600) return 'weeks';
    if (age < 94608000) return 'months';
    return 'years';
}

function activityLabel(session) {
    const date = activityDate(session);
    if (!date) return '?';
    const age = Math.max((Date.now() - date.getTime()) / 1000, 0);
    switch (activityBucket(session)) {
        case 'seconds': return `${Math.max(Math.floor(age), 1)}s`;
        case 'minutes': return `${Math.max(Math.floor(age / 60), 1)}m`;
        case 'hours': return `${Math.max(Math.floor(age / 3600), 1)}h`;
        case 'days': return `${Math.max(Math.floor(age / 86400), 1)}d`;
        case 'weeks': return `${Math.max(Math.floor(age / 604800), 1)}w`;
        case 'months': return `${Math.max(Math.floor(age / 2592000), 1)}mo`;
        case 'years': return `${Math.max(Math.floor(age / 31557600), 1)}y`;
        default: return '?';
    }
}

function activityHelpText(session) {
    const date = activityDate(session);
    return date ? `Session activity ${relativeTime(date)}.` : 'No recorded recent activity.';
}

function relativeTime(date) {
    const diffSeconds = Math.round((date.getTime() - Date.now()) / 1000);
    const divisions = [
        { amount: 60, unit: 'second' },
        { amount: 60, unit: 'minute' },
        { amount: 24, unit: 'hour' },
        { amount: 7, unit: 'day' },
        { amount: 4.345, unit: 'week' },
        { amount: 12, unit: 'month' },
        { amount: Infinity, unit: 'year' },
    ];
    let duration = diffSeconds;
    for (const division of divisions) {
        if (Math.abs(duration) < division.amount) {
            return new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' }).format(Math.round(duration), division.unit);
        }
        duration /= division.amount;
    }
    return date.toLocaleString();
}

function pullRequestSummary(session) {
    const pr = session.metadata?.pr;
    if (!pr) return null;

    if (session.metadata?.pr_state === 'MERGED') return `${pr} M`;
    if (session.metadata?.pr_state === 'CLOSED') return `${pr} X`;

    const codes = [];
    switch (session.metadata?.pr_review) {
        case 'APPROVED': codes.push('A'); break;
        case 'CHANGES_REQUESTED': codes.push('CR'); break;
        case 'REVIEW_REQUIRED': codes.push('RR'); break;
        case 'PENDING': codes.push('P'); break;
    }
    switch (session.metadata?.pr_merge_state) {
        case 'DIRTY': codes.push('D'); break;
        case 'BLOCKED': codes.push('B'); break;
        case 'CLEAN': codes.push('C'); break;
    }
    return codes.length ? `${pr} ${codes.join(' ')}` : pr;
}

function pullRequestTone(session) {
    if (session.metadata?.pr_state === 'MERGED') return 'done';
    if (session.metadata?.pr_state === 'CLOSED') return 'unknown';
    if (session.metadata?.pr_review === 'CHANGES_REQUESTED'
        || session.metadata?.pr_merge_state === 'DIRTY'
        || session.metadata?.pr_merge_state === 'BLOCKED') {
        return 'waiting-human';
    }
    if (session.metadata?.pr_review === 'APPROVED' || session.metadata?.pr_merge_state === 'CLEAN') {
        return 'active';
    }
    return 'idle';
}

function pullRequestHelpText(session) {
    const parts = [];
    if (session.metadata?.pr) parts.push(`PR #${session.metadata.pr}`);
    if (session.metadata?.pr_state) parts.push(session.metadata.pr_state);
    if (session.metadata?.pr_review) parts.push(session.metadata.pr_review);
    if (session.metadata?.pr_merge_state) parts.push(session.metadata.pr_merge_state);
    return parts.join(' · ') || 'Pull request summary';
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
    renderSelectedSessionSummary();
    placeholderEl.classList.add('hidden');
    document.querySelectorAll('.session-item').forEach(el => {
        el.classList.toggle('selected', el.dataset.name === name);
    });

    closeSocket();

    const term = ensureTerminal();
    term.reset();
    state.fitAddon.fit();

    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = `${proto}//${location.host}/ws/sessions/${encodeURIComponent(name)}${tokenQuery()}`;
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    state.socket = ws;

    ws.addEventListener('open', () => {
        sendResize();
        term.focus();
    });

    ws.addEventListener('message', (ev) => {
        if (typeof ev.data === 'string') {
            term.writeln(ev.data);
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
            const code = ch.charCodeAt(0) - 96; // 'a' to 1
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
function syncControls() {
    viewModeButtons.forEach(button => {
        const selected = button.dataset.viewMode === state.viewMode;
        button.classList.toggle('selected', selected);
        button.setAttribute('aria-selected', String(selected));
    });

    orderModeButtons.forEach(button => {
        const selected = button.dataset.orderMode === state.orderMode;
        button.classList.toggle('selected', selected);
    });
}

function setupControls() {
    viewModeButtons.forEach(button => {
        button.addEventListener('click', () => {
            state.viewMode = button.dataset.viewMode;
            localStorage.setItem('swiftmux.viewMode', state.viewMode);
            syncControls();
            renderSessionList();
        });
    });

    orderModeButtons.forEach(button => {
        button.addEventListener('click', () => {
            state.orderMode = button.dataset.orderMode;
            localStorage.setItem('swiftmux.orderMode', state.orderMode);
            syncControls();
            renderSessionList();
            renderSelectedSessionSummary();
        });
    });

    syncControls();
}

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
loadToken();
setupControls();
fetchSessions();
state.refreshTimer = setInterval(fetchSessions, REFRESH_INTERVAL_MS);
setupKeybar();
