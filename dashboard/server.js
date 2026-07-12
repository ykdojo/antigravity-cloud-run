const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync, spawn } = require('child_process');

// SSE clients
const sseClients = new Set();

// Watch Docker events for agrun containers
let dockerEvents;
function startDockerEvents() {
    dockerEvents = spawn('docker', ['events', '--filter', 'name=agrun', '--format', '{{.Action}}']);
    dockerEvents.stdout.on('data', (data) => {
        const action = data.toString().trim();
        if (['start', 'stop', 'die', 'destroy', 'create'].includes(action)) {
            // Notify all SSE clients
            sseClients.forEach(res => {
                res.write(`data: ${action}\n\n`);
            });
        }
    });
    dockerEvents.on('error', () => {});
    dockerEvents.on('close', () => {
        // Restart if it dies
        setTimeout(startDockerEvents, 1000);
    });
}
startDockerEvents();

const PORT = 7680;
const TEMPLATE_PATH = path.join(__dirname, 'template.html');
const CLOUD_CONFIG_PATH = path.join(process.env.HOME, '.config', 'agrun', 'cloud.json');

// Cloud sessions (Cloud Run services, one per session)

// Written by scripts/deploy-cloud.sh on successful deploy
function getCloudConfig() {
    try {
        return JSON.parse(fs.readFileSync(CLOUD_CONFIG_PATH, 'utf8'));
    } catch (e) {
        return null;
    }
}

// Failed deploys: service name -> { error, log }. Shown in the dashboard
// until dismissed or the session is redeployed.
const cloudDeployErrors = new Map();

// Dismissed deploy failures: service name -> log mtime at dismissal. Keeps
// the log sweep below from resurfacing an error the user already dismissed
// (a newer log means a new attempt, which may fail again).
const dismissedDeployErrors = new Map();

function deployLogPath(name) {
    return path.join(process.env.HOME, '.config', 'agrun', `deploy-${name.replace('agrun-', '')}.log`);
}

function logTail(logPath, fallback) {
    try {
        const lines = fs.readFileSync(logPath, 'utf8').trim().split('\n').filter(l => l.trim());
        const tail = lines.slice(-2).join(' | ');
        if (tail) return tail;
    } catch (e) {}
    return fallback;
}

// Deploys in flight, found by scanning processes rather than a state file:
// survives dashboard restarts and also sees deploys started from the CLI
function runningDeploys() {
    const names = new Set();
    try {
        execSync('ps -axo command', { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 })
            .split('\n').forEach(line => {
                if (!/deploy-cloud\.sh/.test(line)) return;
                const m = line.match(/-s[= ]+([a-z0-9-]+)/);
                names.add(`agrun-${m ? m[1] : 'default'}`);
            });
    } catch (e) {}
    return names;
}

// Deploys that died without us seeing their exit (e.g. while the dashboard
// was down): a recent log with no running process and no final "Deployed."
// marker. The time window keeps old logs from resurfacing forever.
const DEPLOY_LOG_WINDOW_MS = 15 * 60 * 1000;

function sweepDeadDeploys(running) {
    const dir = path.join(process.env.HOME, '.config', 'agrun');
    try {
        fs.readdirSync(dir).forEach(f => {
            const m = f.match(/^deploy-(.+)\.log$/);
            if (!m) return;
            const name = `agrun-${m[1]}`;
            if (running.has(name) || cloudDeployErrors.has(name)) return;
            const logPath = path.join(dir, f);
            const stat = fs.statSync(logPath);
            if (Date.now() - stat.mtimeMs > DEPLOY_LOG_WINDOW_MS) return;
            if ((dismissedDeployErrors.get(name) || 0) >= stat.mtimeMs) return;
            if (/^Deployed\./m.test(fs.readFileSync(logPath, 'utf8'))) return;
            cloudDeployErrors.set(name, { error: logTail(logPath, 'deploy ended unexpectedly'), log: logPath });
        });
    } catch (e) {}
}

// Live proxies: service name -> { port, proc }. `gcloud run services proxy`
// opens an IAM-authenticated tunnel at localhost:port, which the dashboard can
// iframe just like a local container (IAM is still enforced on every request).
const cloudProxies = new Map();
let nextProxyPort = 7781;

// Real terminal readiness: service name -> true once agy has painted. The
// iframe is cross-origin so the page can't inspect it; instead the server opens
// the ttyd WebSocket itself and watches for agy's banner. This connecting also
// warms the instance (first WS connect triggers agy launch in the container).
const cloudReady = new Map();

function probeTerminalReady(name, port) {
    let settled = false;
    const done = () => { if (!settled) { settled = true; cloudReady.set(name, true); } };
    const attempt = async (triesLeft) => {
        if (!cloudProxies.has(name)) return; // disconnected
        let token = '';
        try {
            const r = await fetch(`http://127.0.0.1:${port}/token`);
            token = (await r.json()).token || '';
        } catch (e) {
            if (triesLeft > 0) return setTimeout(() => attempt(triesLeft - 1), 1500);
        }
        let ws;
        try {
            ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, 'tty');
        } catch (e) {
            if (triesLeft > 0) return setTimeout(() => attempt(triesLeft - 1), 1500);
            return done();
        }
        ws.binaryType = 'arraybuffer';
        let acc = '';
        const giveUp = setTimeout(() => { try { ws.close(); } catch (e) {} done(); }, 90000);
        ws.onopen = () => ws.send(JSON.stringify({ AuthToken: token, columns: 120, rows: 30 }));
        ws.onmessage = (ev) => {
            const buf = new Uint8Array(ev.data);
            if (String.fromCharCode(buf[0]) === '0') { // OUTPUT frame
                acc += new TextDecoder().decode(buf.slice(1));
                if (/Antigravity CLI/.test(acc)) {
                    clearTimeout(giveUp);
                    try { ws.close(); } catch (e) {}
                    done();
                }
            }
        };
        ws.onerror = () => {};
        ws.onclose = () => {
            clearTimeout(giveUp);
            if (settled || !cloudProxies.has(name)) return;
            if (triesLeft > 0) setTimeout(() => attempt(triesLeft - 1), 1500);
            else done(); // give up gracefully - dismiss the overlay rather than hang
        };
    };
    attempt(20);
}

function startCloudProxy(name, callback) {
    const existing = cloudProxies.get(name);
    if (existing) {
        callback({ success: true, port: existing.port, url: `http://localhost:${existing.port}` });
        return;
    }
    const config = getCloudConfig();
    if (!config) {
        callback({ success: false, error: 'no cloud config' });
        return;
    }
    const port = nextProxyPort++;
    const proc = spawn('gcloud', [
        'run', 'services', 'proxy', name,
        '--project', config.project, '--region', config.region, '--port', String(port)
    ], { detached: false, stdio: 'ignore' });
    cloudProxies.set(name, { port, proc });
    cloudReady.delete(name);
    proc.on('exit', () => { cloudProxies.delete(name); cloudReady.delete(name); });
    // Poll until the proxy answers (auth handshake + cold start can take a bit)
    const http = require('http');
    let tries = 0;
    const check = () => {
        tries++;
        const req = http.get({ host: '127.0.0.1', port, timeout: 2000 }, res => {
            res.destroy();
            probeTerminalReady(name, port); // watch for agy to finish painting
            callback({ success: true, port, url: `http://localhost:${port}` });
        });
        req.on('error', () => {
            if (!cloudProxies.has(name)) { callback({ success: false, error: 'proxy exited' }); return; }
            if (tries >= 30) { callback({ success: true, port, url: `http://localhost:${port}`, slow: true }); return; }
            setTimeout(check, 1000);
        });
        req.on('timeout', () => req.destroy());
    };
    setTimeout(check, 1000);
}

function stopCloudProxy(name, callback) {
    const entry = cloudProxies.get(name);
    if (entry) {
        try { entry.proc.kill(); } catch (e) {}
        cloudProxies.delete(name);
    }
    cloudReady.delete(name);
    if (callback) callback({ success: true });
}

// Last "==> ..." line of a session's deploy log: the step it's on right now.
// During the docker build/push, append the live sub-step (Dockerfile step or
// pushed-layer count).
function currentDeployStep(name) {
    try {
        const lines = fs.readFileSync(deployLogPath(name), 'utf8').split('\n');
        let step = null, stepIdx = -1;
        for (let i = lines.length - 1; i >= 0; i--) {
            if (lines[i].startsWith('==> ')) { step = lines[i].slice(4).replace(/\.{3}$/, ''); stepIdx = i; break; }
        }
        if (!step) return null;
        if (step.startsWith('Building image')) {
            for (let i = lines.length - 1; i > stepIdx; i--) {
                const m = lines[i].match(/^#\d+ \[\s*(\d+\/\d+)\] (.*)/);
                if (m) return `building image ${m[1]}: ${m[2]}`;
            }
        }
        if (step.startsWith('Pushing image')) {
            const pushed = lines.slice(stepIdx).filter(l => /: Pushed\s*$/.test(l)).length;
            if (pushed) return `pushing image: ${pushed} layers pushed`;
        }
        return step;
    } catch (e) {}
    return null;
}

// Deploys in flight or failed, for sessions not (yet) in the service list
function pendingCloudSessions(existing, running) {
    const sessions = [];
    running.forEach(name => {
        if (!existing.some(s => s.name === name)) {
            sessions.push({ name, displayName: name.replace('agrun-', ''), ready: false, alwaysOn: false, deploying: true, step: currentDeployStep(name), proxyCmd: '' });
        }
    });
    cloudDeployErrors.forEach(({ error, log }, name) => {
        if (!existing.some(s => s.name === name)) {
            sessions.push({ name, displayName: name.replace('agrun-', ''), ready: false, alwaysOn: false, deploying: false, failed: true, error, log, proxyCmd: '' });
        }
    });
    return sessions;
}

function getCloudSessions(callback) {
    const running = runningDeploys();
    sweepDeadDeploys(running);
    const config = getCloudConfig();
    if (!config) {
        callback({ configured: false, sessions: pendingCloudSessions([], running) });
        return;
    }
    const { exec } = require('child_process');
    const cmd = `gcloud run services list --project ${config.project} --region ${config.region}` +
        ` --filter 'metadata.labels.agrun=session' --format json`;
    exec(cmd, { encoding: 'utf8', timeout: 30000 }, (err, stdout) => {
        if (err) {
            callback({ configured: true, error: err.message.split('\n')[0], sessions: [] });
            return;
        }
        let services = [];
        try { services = JSON.parse(stdout); } catch (e) {}
        services = services.filter(svc => !cloudDeleting.has(svc.metadata.name));
        const sessions = services.map(svc => {
            const name = svc.metadata.name;
            const ready = (svc.status?.conditions || []).some(c => c.type === 'Ready' && c.status === 'True');
            const minInstances = svc.spec?.template?.metadata?.annotations?.['autoscaling.knative.dev/minScale'] || '0';
            const proxy = cloudProxies.get(name);
            return {
                name,
                displayName: name.replace('agrun-', ''),
                ready,
                alwaysOn: minInstances !== '0',
                deploying: running.has(name),
                step: running.has(name) ? currentDeployStep(name) : null,
                connected: !!proxy,
                terminalReady: !!cloudReady.get(name),
                url: proxy ? `http://localhost:${proxy.port}` : null,
                proxyCmd: `gcloud run services proxy ${name} --project ${config.project} --region ${config.region} --port 7681`
            };
        });
        // Include deploys in flight or failed that don't show up in the list yet
        sessions.push(...pendingCloudSessions(sessions, running));
        callback({ configured: true, project: config.project, region: config.region, sessions });
    });
}

function createCloudSession(options, callback) {
    const name = (options.name || 'default').trim();
    const serviceName = `agrun-${name}`;
    if (!/^[a-z0-9-]+$/.test(name)) {
        callback({ success: false, error: 'name must be lowercase letters, digits, dashes' });
        return;
    }
    if (runningDeploys().has(serviceName)) {
        callback({ success: false, error: `${serviceName} is already deploying` });
        return;
    }
    const scriptPath = path.join(__dirname, '..', 'scripts', 'deploy-cloud.sh');
    const args = ['-s', name];
    if (!options.zeroScale) args.push('-a'); // scale-to-zero is the script default
    const config = getCloudConfig();
    if (config) args.push('-P', config.project, '-r', config.region);
    cloudDeployErrors.delete(serviceName);
    const logPath = deployLogPath(serviceName);
    const out = fs.openSync(logPath, 'w');
    const child = spawn(scriptPath, args, { detached: true, stdio: ['ignore', out, out] });
    child.on('error', err => {
        try { fs.closeSync(out); } catch (e) {}
        cloudDeployErrors.set(serviceName, { error: `could not start deploy script: ${err.message}`, log: logPath });
    });
    child.on('exit', code => {
        try { fs.closeSync(out); } catch (e) {}
        if (code === 0) return;
        const fallback = code === 127
            ? 'gcloud not found - install the Google Cloud SDK and log in (gcloud auth login)'
            : `deploy script exited immediately (exit ${code}) - is gcloud installed and logged in?`;
        cloudDeployErrors.set(serviceName, { error: logTail(logPath, fallback), log: logPath });
    });
    child.unref();
    callback({ success: true, deploying: serviceName, log: logPath });
}

// Services mid-deletion: hidden from the session list right away, while
// `gcloud run services delete` finishes in the background
const cloudDeleting = new Set();

function deleteCloudSession(name, callback) {
    const config = getCloudConfig();
    if (!config) {
        callback({ success: false });
        return;
    }
    const { exec } = require('child_process');
    cloudDeleting.add(name);
    exec(`gcloud run services delete ${name} --project ${config.project} --region ${config.region} --quiet`,
        { timeout: 120000 }, (err) => {
            cloudDeleting.delete(name);
            if (err) cloudDeployErrors.set(name, { error: `delete failed: ${err.message.split('\n')[0]}`, log: '' });
        });
    callback({ success: true });
}

function getSessions() {
    const sessions = [];

    // Get all agrun containers (running and stopped)
    try {
        const output = execSync(
            `docker ps -a --format '{{.Names}}\\t{{.Status}}' --filter 'name=agrun'`,
            { encoding: 'utf8' }
        );

        output.trim().split('\n').filter(Boolean).forEach(line => {
            const [name, status] = line.split('\t');
            const isRunning = status.startsWith('Up');

            let port = null;
            let volume = '-';

            if (isRunning) {
                // Get port for running containers
                try {
                    const portOutput = execSync(
                        `docker ps --format '{{.Ports}}' --filter 'name=^${name}$'`,
                        { encoding: 'utf8' }
                    ).trim();
                    const portMatch = portOutput.match(/:(\d+)->7681/);
                    port = portMatch ? portMatch[1] : null;
                } catch (e) {}
            }

            // Get volume mount (exclude internal projects mount)
            try {
                const inspect = execSync(
                    `docker inspect ${name} --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}:{{.Destination}}\n{{end}}{{end}}'`,
                    { encoding: 'utf8' }
                ).trim();
                const mounts = inspect.split('\n').filter(m =>
                    m && !m.endsWith(':/home/agrun/.gemini')
                );
                volume = mounts.join(', ') || '-';
            } catch (e) {}

            sessions.push({
                name,
                port,
                url: port ? `http://localhost:${port}` : null,
                volume,
                active: isRunning
            });
        });
    } catch (e) {}

    // Sort: active first, then by name
    sessions.sort((a, b) => {
        if (a.active !== b.active) return b.active - a.active;
        return a.name.localeCompare(b.name);
    });

    return sessions;
}

function stopContainer(name) {
    try {
        execSync(`docker stop -t 1 ${name}`, { encoding: 'utf8' });
        return true;
    } catch (e) {
        return false;
    }
}

function deleteContainer(name) {
    try {
        execSync(`docker rm ${name}`, { encoding: 'utf8' });
        return true;
    } catch (e) {
        return false;
    }
}

function createContainer(options) {
    try {
        const scriptPath = path.join(__dirname, '..', 'scripts', 'new.sh');
        let args = '-n'; // always skip browser open (we handle it in frontend)

        if (options.name) {
            args += ` -s ${options.name}`;
        }
        if (options.volume) {
            args += ` -v ${options.volume}`;
        }
        const output = execSync(`${scriptPath} ${args}`, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });

        // Extract URL from output
        const urlMatch = output.match(/http:\/\/localhost:\d+/);
        const url = urlMatch ? urlMatch[0] : null;

        return { success: true, url };
    } catch (e) {
        // execSync error has stderr as Buffer
        let error = 'Failed to create session';
        if (e.stderr && e.stderr.length > 0) {
            error = e.stderr.toString().trim();
        } else if (e.message) {
            error = e.message;
        }
        return { success: false, error };
    }
}

function startContainer(name) {
    try {
        execSync(`docker start ${name}`, { encoding: 'utf8' });
        // Start ttyd inside the container
        const secretsDir = process.env.HOME + '/.config/agrun/.secrets';
        let envFlags = '';
        try {
            const files = fs.readdirSync(secretsDir);
            files.forEach(f => {
                const val = fs.readFileSync(`${secretsDir}/${f}`, 'utf8').trim();
                envFlags += ` -e ${f}=${val}`;
            });
        } catch (e) {}

        const sessionName = name.replace('agrun-', '');
        const title = `Antigravity on Cloud Run - ${sessionName}`;
        execSync(`docker exec ${envFlags} -d ${name} ttyd -W -t titleFixed="${title}" -t fontSize=16 -p 7681 /home/agrun/ttyd-wrapper.sh`, { encoding: 'utf8' });

        // Get the port
        const portInfo = execSync(`docker ps --filter "name=^${name}$" --format "{{.Ports}}"`, { encoding: 'utf8' }).trim();
        const portMatch = portInfo.match(/:(\d+)->/);
        const port = portMatch ? portMatch[1] : '7681';

        return { success: true, url: `http://localhost:${port}` };
    } catch (e) {
        return { success: false };
    }
}

function renderContent(sessions) {
    if (sessions.length === 0) {
        return `<div class="empty">
            <p>no sessions</p>
            <table class="help">
                <tr><td><code>./scripts/run.sh</code></td><td>default session</td></tr>
                <tr><td><code>./scripts/run.sh -s name</code></td><td>named session</td></tr>
                <tr><td><code>./scripts/run.sh -n</code></td><td>skip opening browser</td></tr>
                <tr><td><code>./scripts/run.sh -v ~/myproject:/home/agrun/myproject</code></td><td>mount volume</td></tr>
            </table>
            <p class="tip">tip: ${['in a session, press q or scroll to the bottom to exit scroll mode and resume typing', 'on this dashboard, press shift-tab or tab and enter to quickly create a new session', 'run node scripts/manage-env.js to manage environment variables'][Math.floor(Math.random() * 3)]}</p>
        </div>`;
    }

    const sessionRows = sessions.map(s => {
        const displayName = s.name.replace('agrun-', '');
        const displayUrl = s.url ? s.url.replace('http://', '') : '';
        const urlCell = s.active
            ? `<a href="${s.url}" target="_blank">${displayUrl}</a>`
            : `<button class="start-btn" onclick="startSession('${s.name}')">start</button>`;
        const actionBtn = s.active
            ? `<button class="stop-btn" onclick="stopSession('${s.name}', this)">stop</button>`
            : `<button class="delete-btn" onclick="deleteSession('${s.name}', this)">delete</button>`;

        return `
        <tr class="${s.active ? '' : 'inactive-row'}" data-name="${s.name}" data-url="${s.url || ''}">
            <td><a href="#" class="session-name" onclick="showSessionInfo('${s.name}'); return false;">${displayName}</a></td>
            <td>${urlCell}</td>
            <td class="volume">${s.volume || '-'}</td>
            <td>${actionBtn}</td>
        </tr>
        `;
    }).join('');

    const activeSessions = sessions.filter(s => s.active);
    const iframes = activeSessions.map(s => `
        <div class="frame" id="frame-${s.name}">
            <div class="frame-bar">
                <span>${s.name.replace('agrun-', '')}</span>
                <div class="frame-actions">
                    <a href="#" class="frame-stop" onclick="stopSessionLink('${s.name}', this); return false;">stop</a>
                    <a href="#" onclick="document.querySelector('#frame-${s.name} iframe').src='${s.url}'; return false;">refresh</a>
                    <a href="${s.url}" target="_blank">open</a>
                </div>
            </div>
            <iframe src="${s.url}"></iframe>
        </div>
    `).join('');

    return `
    <div class="table-wrapper">
        <table class="sessions">
            <thead><tr><th>Session</th><th>URL</th><th>Volume <span class="info-icon">i<span class="tooltip">Conversation history is persisted via a volume mount not shown here</span></span></th><th></th></tr></thead>
            <tbody>${sessionRows}</tbody>
        </table>
    </div>
    ${activeSessions.length > 0 ? `<div class="frames${activeSessions.length === 1 ? ' single' : ''}">${iframes}</div>` : ''}
    `;
}

const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${PORT}`);

    if (url.pathname === '/api/sessions') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(getSessions()));
    } else if (url.pathname === '/api/stop' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const { name } = JSON.parse(body);
            const success = stopContainer(name);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success }));
        });
    } else if (url.pathname === '/api/delete' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const { name } = JSON.parse(body);
            const success = deleteContainer(name);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success }));
        });
    } else if (url.pathname === '/api/start' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const { name } = JSON.parse(body);
            const result = startContainer(name);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(result));
        });
    } else if (url.pathname === '/api/create' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const options = JSON.parse(body);
            const result = createContainer(options);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(result));
        });
    } else if (url.pathname === '/api/cloud-sessions') {
        getCloudSessions(result => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(result));
        });
    } else if (url.pathname === '/api/cloud-create' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            createCloudSession(JSON.parse(body), result => {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(result));
            });
        });
    } else if (url.pathname === '/api/cloud-delete' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const { name } = JSON.parse(body);
            stopCloudProxy(name);
            deleteCloudSession(name, result => {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(result));
            });
        });
    } else if (url.pathname === '/api/cloud-connect' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const { name } = JSON.parse(body);
            startCloudProxy(name, result => {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(result));
            });
        });
    } else if (url.pathname === '/api/cloud-disconnect' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const { name } = JSON.parse(body);
            stopCloudProxy(name, result => {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(result));
            });
        });
    } else if (url.pathname === '/api/cloud-dismiss-error' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            const { name } = JSON.parse(body);
            cloudDeployErrors.delete(name);
            try { dismissedDeployErrors.set(name, fs.statSync(deployLogPath(name)).mtimeMs); } catch (e) {}
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true }));
        });
    } else if (url.pathname === '/api/events') {
        // Server-Sent Events for real-time updates
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive'
        });
        res.write('data: connected\n\n');
        sseClients.add(res);
        req.on('close', () => sseClients.delete(res));
    } else {
        const template = fs.readFileSync(TEMPLATE_PATH, 'utf8');
        const content = renderContent(getSessions());
        const html = template.replace('{{CONTENT}}', content);
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(html);
    }
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`Dashboard: http://localhost:${PORT}`);
});

// Kill any live cloud proxies when the dashboard exits
function shutdownProxies() {
    cloudProxies.forEach(({ proc }) => { try { proc.kill(); } catch (e) {} });
    process.exit(0);
}
process.on('SIGINT', shutdownProxies);
process.on('SIGTERM', shutdownProxies);
