import Foundation

/// Embedded web UI served by the WebGUIServer.
public enum EmbeddedWebUI {

    public static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>TrackSplitter</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }

      :root {
        --bg: #0f0f14;
        --surface: #1a1a24;
        --border: #2a2a3a;
        --accent: #7c6af0;
        --accent2: #f06a9c;
        --text: #e8e8f0;
        --muted: #8888aa;
        --green: #4ade80;
        --red: #f87171;
      }

      body {
        font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif;
        background: var(--bg);
        color: var(--text);
        min-height: 100vh;
        display: flex;
        flex-direction: column;
        align-items: center;
        padding: 40px 20px;
      }

      .header {
        text-align: center;
        margin-bottom: 40px;
      }

      .header h1 {
        font-size: 2.2rem;
        font-weight: 700;
        background: linear-gradient(135deg, var(--accent), var(--accent2));
        -webkit-background-clip: text;
        -webkit-text-fill-color: transparent;
        margin-bottom: 6px;
      }

      .header p {
        color: var(--muted);
        font-size: 0.95rem;
      }

      .drop-zone {
        width: 100%;
        max-width: 560px;
        border: 2px dashed var(--border);
        border-radius: 20px;
        padding: 60px 40px;
        text-align: center;
        cursor: pointer;
        transition: border-color 0.2s, background 0.2s, transform 0.15s;
        background: var(--surface);
        margin-bottom: 32px;
      }

      .drop-zone:hover, .drop-zone.drag-over {
        border-color: var(--accent);
        background: rgba(124, 106, 240, 0.06);
        transform: translateY(-2px);
      }

      .drop-zone-icon {
        font-size: 3.5rem;
        margin-bottom: 16px;
      }

      .drop-zone h2 {
        font-size: 1.2rem;
        font-weight: 600;
        margin-bottom: 8px;
      }

      .drop-zone p {
        color: var(--muted);
        font-size: 0.875rem;
      }

      .drop-zone input[type=file] {
        display: none;
      }

      /* Requirements section */
      .requirements {
        width: 100%;
        max-width: 560px;
        display: flex;
        gap: 12px;
        margin-bottom: 32px;
        flex-wrap: wrap;
      }

      .req-badge {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        background: var(--surface);
        border: 1px solid var(--border);
        border-radius: 100px;
        padding: 6px 14px;
        font-size: 0.8rem;
        color: var(--muted);
      }

      .req-badge.ok { color: var(--green); border-color: var(--green); }
      .req-badge.fail { color: var(--red); border-color: var(--red); }

      /* Progress */
      .progress-section {
        width: 100%;
        max-width: 560px;
        display: none;
        flex-direction: column;
        gap: 16px;
      }

      .progress-section.visible { display: flex; }

      .progress-track-list {
        background: var(--surface);
        border: 1px solid var(--border);
        border-radius: 16px;
        overflow: hidden;
      }

      .progress-track-item {
        display: flex;
        align-items: center;
        gap: 12px;
        padding: 12px 16px;
        border-bottom: 1px solid var(--border);
        font-size: 0.875rem;
        transition: background 0.2s;
      }

      .progress-track-item:last-child { border-bottom: none; }

      .track-num {
        width: 28px;
        height: 28px;
        border-radius: 8px;
        background: var(--border);
        display: flex;
        align-items: center;
        justify-content: center;
        font-size: 0.75rem;
        font-weight: 600;
        flex-shrink: 0;
        color: var(--muted);
      }

      .track-num.done { background: var(--green); color: #000; }
      .track-num.active { background: var(--accent); color: #fff; }

      .track-title { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .track-status { font-size: 0.75rem; color: var(--muted); }

      /* Status message */
      .status-msg {
        text-align: center;
        padding: 16px;
        border-radius: 12px;
        background: var(--surface);
        border: 1px solid var(--border);
        font-size: 0.9rem;
      }

      .status-msg.success { border-color: var(--green); color: var(--green); }
      .status-msg.error { border-color: var(--red); color: var(--red); }
      .status-msg.info { border-color: var(--accent); color: var(--accent); }

      .reveal-btn {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        background: var(--accent);
        color: #fff;
        border: none;
        border-radius: 12px;
        padding: 12px 24px;
        font-size: 0.95rem;
        font-weight: 600;
        cursor: pointer;
        transition: opacity 0.2s, transform 0.15s;
        text-decoration: none;
      }

      .reveal-btn:hover { opacity: 0.85; transform: translateY(-1px); }

      .log-area {
        background: #0a0a0f;
        border: 1px solid var(--border);
        border-radius: 12px;
        padding: 16px;
        font-family: 'SF Mono', 'Menlo', monospace;
        font-size: 0.8rem;
        color: var(--muted);
        max-height: 200px;
        overflow-y: auto;
        white-space: pre-wrap;
        word-break: break-all;
      }

      .log-area .info { color: var(--accent); }
      .log-area .ok { color: var(--green); }
      .log-area .warn { color: #fbbf24; }
      .log-area .err { color: var(--red); }

      /* Overall progress bar */
      .overall-bar-wrap {
        background: var(--border);
        border-radius: 8px;
        height: 8px;
        overflow: hidden;
      }

      .overall-bar {
        height: 100%;
        background: linear-gradient(90deg, var(--accent), var(--accent2));
        border-radius: 8px;
        transition: width 0.4s ease;
        width: 0%;
      }

    </style>
    </head>
    <body>

      <div class="header">
        <h1>🎧 TrackSplitter</h1>
        <p>Split FLAC+CUE albums into individual tracks</p>
      </div>

      <div class="requirements" id="requirements">
        <!-- Populated by JS -->
      </div>

      <div class="drop-zone" id="dropZone">
        <div class="drop-zone-icon">🎵</div>
        <h2>Drop your FLAC file here</h2>
        <p>A .cue file with the same name is required in the same directory</p>
        <input type="file" id="fileInput" accept=".flac">
      </div>

      <div class="progress-section" id="progressSection">
        <div class="overall-bar-wrap">
          <div class="overall-bar" id="overallBar"></div>
        </div>
        <div class="status-msg" id="statusMsg"></div>
        <div class="progress-track-list" id="trackList"></div>
        <div class="log-area" id="logArea"></div>
        <div id="actions" style="text-align:center;"></div>
      </div>

      <script>
        // ── Check requirements ──────────────────────────────────────
        function checkRequirements() {
          const el = document.getElementById('requirements');
          const checks = [
            { name: 'ffmpeg', cmd: 'which ffmpeg' },
            { name: 'python3 + mutagen', cmd: 'python3 -c "import mutagen"' },
          ];
          checks.forEach(c => {
            const badge = document.createElement('span');
            badge.className = 'req-badge';
            badge.id = 'req-' + c.name;
            badge.textContent = '⏳ Checking ' + c.name + '...';
            el.appendChild(badge);
          });
        }

        function log(msg, cls='') {
          const el = document.getElementById('logArea');
          const span = document.createElement('span');
          span.className = cls;
          span.textContent = msg;
          el.appendChild(span);
          el.scrollTop = el.scrollHeight;
        }

        // ── Drop zone ──────────────────────────────────────────────
        const dropZone = document.getElementById('dropZone');
        const fileInput = document.getElementById('fileInput');

        dropZone.addEventListener('click', () => fileInput.click());

        dropZone.addEventListener('dragover', e => {
          e.preventDefault();
          dropZone.classList.add('drag-over');
        });

        dropZone.addEventListener('dragleave', () => {
          dropZone.classList.remove('drag-over');
        });

        dropZone.addEventListener('drop', e => {
          e.preventDefault();
          dropZone.classList.remove('drag-over');
          const file = e.dataTransfer.files[0];
          if (file) handleFile(file);
        });

        fileInput.addEventListener('change', () => {
          if (fileInput.files[0]) handleFile(fileInput.files[0]);
        });

        // ── File upload & processing ────────────────────────────────
        let eventSource = null;
        let outputPath = null;

        function handleFile(file) {
          log('Selected: ' + file.name + ' (' + formatBytes(file.size) + ')\\n', 'info');

          // Show progress UI
          document.getElementById('progressSection').classList.add('visible');
          document.getElementById('trackList').innerHTML = '';
          document.getElementById('logArea').innerHTML = '';
          document.getElementById('statusMsg').textContent = 'Uploading...';
          document.getElementById('statusMsg').className = 'status-msg info';
          document.getElementById('overallBar').style.width = '0%';
          document.getElementById('actions').innerHTML = '';

          const formData = new FormData();
          formData.append('flac', file);

          // Also send .cue if it exists (user should drag both)
          // We'll rely on the .cue being alongside the FLAC server-side

          fetch('/upload', { method: 'POST', body: formData })
            .then(r => {
              if (!r.ok) throw new Error('Upload failed: ' + r.status);
              log('Upload complete. Processing...\\n', 'info');
            })
            .catch(err => {
              log('Upload error: ' + err.message + '\\n', 'err');
              setStatus('Upload failed', 'error');
            });
        }

        // ── SSE for progress ──────────────────────────────────────
        function connectSSE() {
          if (eventSource) eventSource.close();
          eventSource = new EventSource('/progress');

          eventSource.addEventListener('progress', e => {
            const msg = e.data;
            log(msg + '\\n');

            // Parse track progress from log messages
            if (msg.includes('Splitting track')) {
              const m = msg.match(/Splitting track (\\d+)/);
              if (m) updateTrackActive(parseInt(m[1]));
            } else if (msg.includes('DONE') || msg.includes('saved')) {
              // Extract track number
            }
          });

          eventSource.addEventListener('complete', e => {
            outputPath = e.data;
            eventSource.close();
            log('\\n✅ Done! Tracks saved to: ' + outputPath, 'ok');
            setStatus('Split complete!', 'success');
            showRevealBtn(outputPath);
            document.getElementById('dropZone').style.display = 'none';
          });

          eventSource.addEventListener('error', e => {
            const msg = e.data || 'Unknown error';
            log('\\n❌ Error: ' + msg + '\\n', 'err');
            setStatus('Processing failed: ' + msg, 'error');
            eventSource.close();
          });

          eventSource.onerror = () => {
            // Connection closed by server, clean up
            setTimeout(() => { if (eventSource) eventSource.close(); }, 500);
          };
        }

        function updateTrackActive(n) {
          // Update overall bar
          const pct = Math.round((n / 10) * 100);
          document.getElementById('overallBar').style.width = pct + '%';
          setStatus('Splitting track ' + n + '/10...', 'info');
        }

        function setStatus(msg, cls) {
          const el = document.getElementById('statusMsg');
          el.textContent = msg;
          el.className = 'status-msg ' + (cls || '');
        }

        function showRevealBtn(path) {
          const el = document.getElementById('actions');
          const btn = document.createElement('a');
          btn.className = 'reveal-btn';
          btn.href = '#';
          btn.textContent = '📁 Reveal in Finder';
          btn.onclick = () => { openFinder(path); return false; };
          el.appendChild(btn);

          const resetBtn = document.createElement('button');
          resetBtn.className = 'reveal-btn';
          resetBtn.style.marginLeft = '12px';
          resetBtn.style.background = 'var(--surface)';
          resetBtn.style.border = '1px solid var(--border)';
          resetBtn.textContent = '🔄 Split Another';
          resetBtn.onclick = () => location.reload();
          el.appendChild(resetBtn);
        }

        function openFinder(path) {
          // Use macOS open command via fetch to a special endpoint
          fetch('/reveal?path=' + encodeURIComponent(path));
        }

        function formatBytes(b) {
          if (b > 1024*1024*1024) return (b/1024/1024/1024).toFixed(1) + ' GB';
          if (b > 1024*1024) return (b/1024/1024).toFixed(1) + ' MB';
          return (b/1024).toFixed(1) + ' KB';
        }

        // ── Init ───────────────────────────────────────────────────
        checkRequirements();
        connectSSE();
      </script>
    </body>
    </html>
    """
}
