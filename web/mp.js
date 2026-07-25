/**
 * mp.js — DRIFT online. The client half of the multiplayer server in
 * workers/drift-mp/worker.js.
 *
 * Deliberately a separate file. The game is a single 1490-line index.html, and threading
 * networking through it by hand would leave multiplayer smeared across the whole thing
 * with no way to reason about either half. This module owns the socket, the other players
 * and the server picker; index.html calls four functions and draws what it is given.
 *
 * WHAT COMES OVER THE WIRE. Only actors — attractors, names, scores. The particle field is
 * never transmitted: both ends seed an identical PRNG from (room seed, tick) and compute
 * the same field locally. A thousand particles therefore cost nothing, and everyone is
 * genuinely looking at the same one.
 *
 * COORDINATES. The server thinks in a fixed 1600x900 field so every client agrees
 * regardless of window size; toLocal/toField convert. Sending raw canvas pixels would mean
 * a player on a phone and a player on a desktop occupied different worlds.
 */
(function () {
  'use strict'

  const ENDPOINT = 'https://phronesis-drift-mp.degibug.workers.dev'
  const FIELD = { w: 1600, h: 900 }
  const SEND_HZ = 20                 // input rate; the server ticks at 15 and caps movement

  const MP = {
    connected: false,
    you: null,
    server: null,
    seed: 0,
    tick: 0,
    roundEndsAt: 0,
    others: [],                      // everyone else, already in LOCAL canvas coords
    all: [],                         // including you — for the leaderboard
    error: null,
    latency: 0,
  }

  let ws = null, lastSend = 0, lastPing = 0

  // ── coordinates ──────────────────────────────────────────────────────────
  // Letterboxed so the field keeps its aspect on any screen; a player never gains reach
  // by having a wider window.
  function scale() {
    const cw = window.innerWidth, ch = window.innerHeight
    const s = Math.min(cw / FIELD.w, ch / FIELD.h)
    return { s, ox: (cw - FIELD.w * s) / 2, oy: (ch - FIELD.h * s) / 2 }
  }
  const toLocal = (x, y) => { const { s, ox, oy } = scale(); return { x: x * s + ox, y: y * s + oy } }
  const toField = (x, y) => { const { s, ox, oy } = scale(); return { x: (x - ox) / s, y: (y - oy) / s } }
  MP.toLocal = toLocal
  MP.toField = toField

  // ── the shared field ─────────────────────────────────────────────────────
  // Mirrors mulberry32 in worker.js exactly. If these two ever disagree the game silently
  // desynchronises — players would collect clusters nobody else can see — so this is the
  // one function in either file that must not be "improved" on one side only.
  MP.rng = function (a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0
      let t = Math.imul(a ^ (a >>> 15), 1 | a)
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296
    }
  }

  // ── lobby ────────────────────────────────────────────────────────────────
  MP.fetchServers = async function () {
    const r = await fetch(ENDPOINT + '/servers', { cache: 'no-store' })
    if (!r.ok) throw new Error('lobby unreachable')
    return (await r.json()).servers
  }

  // ── connection ───────────────────────────────────────────────────────────
  MP.connect = function (serverId, name) {
    MP.disconnect()
    MP.error = null
    const url = `${ENDPOINT.replace(/^http/, 'ws')}/ws?server=${encodeURIComponent(serverId)}` +
                `&name=${encodeURIComponent(name || 'drifter')}`
    ws = new WebSocket(url)

    ws.onopen = () => { MP.server = serverId }
    ws.onclose = () => {
      MP.connected = false
      MP.others = []
      // Not an auto-reconnect. A silent retry loop against a full or missing server hides
      // the failure and burns the player's battery; the UI says so and offers the lobby.
      if (!MP.error) MP.error = 'disconnected'
    }
    ws.onerror = () => { MP.error = 'could not reach the server' }

    ws.onmessage = (ev) => {
      let m
      try { m = JSON.parse(ev.data) } catch { return }

      if (m.t === 'welcome') {
        MP.connected = true
        MP.you = m.you
        MP.seed = m.seed
        MP.roundEndsAt = m.roundEndsAt
        MP.server = m.server
        if (typeof MP.onwelcome === 'function') MP.onwelcome(m)
      } else if (m.t === 'state') {
        MP.tick = m.k
        MP.all = m.a
        MP.others = m.a.filter((a) => a.i !== MP.you).map((a) => {
          const p = toLocal(a.x, a.y)
          return { id: a.i, name: a.n, x: p.x, y: p.y, score: a.s, bot: !!a.b, hue: a.h }
        })
      } else if (m.t === 'round') {
        MP.seed = m.seed
        MP.roundEndsAt = m.roundEndsAt
        MP.tick = 0
        if (typeof MP.onround === 'function') MP.onround(m)
      }
    }
  }

  MP.disconnect = function () {
    if (ws) { try { ws.close() } catch (e) {} ws = null }
    MP.connected = false
    MP.others = []
    MP.all = []
  }

  /** Called every frame with the player's attractor in LOCAL coords; throttled internally. */
  MP.sendInput = function (x, y) {
    if (!MP.connected || !ws || ws.readyState !== 1) return
    const now = performance.now()
    if (now - lastSend < 1000 / SEND_HZ) return
    lastSend = now
    const f = toField(x, y)
    try { ws.send(JSON.stringify({ t: 'input', x: Math.round(f.x), y: Math.round(f.y) })) } catch (e) {}
  }

  /** Tell the server a cluster was collected. It checks the claim is near and recent. */
  MP.claim = function (x, y, value) {
    if (!MP.connected || !ws || ws.readyState !== 1) return
    const f = toField(x, y)
    try {
      ws.send(JSON.stringify({ t: 'claim', x: Math.round(f.x), y: Math.round(f.y),
                               value: value | 0, tick: MP.tick }))
    } catch (e) {}
  }

  /** The live board, best first. Bots included — they are competing for real. */
  MP.board = function (n) {
    return MP.all.slice().sort((a, b) => b.s - a.s).slice(0, n || 8)
      .map((a) => ({ name: a.n, score: a.s, bot: !!a.b, you: a.i === MP.you }))
  }

  MP.secondsLeft = function () {
    return Math.max(0, Math.round((MP.roundEndsAt - Date.now()) / 1000))
  }

  // ── the server picker ────────────────────────────────────────────────────
  // DOM rather than canvas: it is a list of choices, and a real <button> is focusable,
  // screen-readable and keyboard-operable for free. The canvas UI elsewhere in this game
  // is none of those things.
  MP.showLobby = function (onPick) {
    const wrap = document.createElement('div')
    wrap.id = 'mp-lobby'
    wrap.innerHTML = `
      <style>
        #mp-lobby{position:fixed;inset:0;z-index:9999;background:rgba(6,8,12,.94);
          display:flex;align-items:center;justify-content:center;padding:20px;
          font-family:ui-monospace,Menlo,monospace;overflow:auto}
        #mp-lobby .box{max-width:560px;width:100%}
        #mp-lobby h2{color:#F2F4F8;font-size:20px;letter-spacing:.02em;margin:0 0 4px;font-weight:600}
        #mp-lobby .sub{color:#8A93A3;font-size:12.5px;margin:0 0 18px;line-height:1.6}
        #mp-lobby .row{display:flex;align-items:center;gap:12px;width:100%;text-align:left;
          background:#11151C;border:1px solid #232A35;border-left:3px solid var(--hue);
          border-radius:10px;padding:12px 14px;margin-bottom:9px;cursor:pointer;
          color:#E7EAF0;font:inherit;transition:border-color .15s,transform .1s}
        #mp-lobby .row:hover,#mp-lobby .row:focus-visible{border-color:#3F4A5C;transform:translateX(2px);outline:none}
        #mp-lobby .nm{font-size:14.5px;font-weight:600;color:var(--hue)}
        #mp-lobby .bl{font-size:11.5px;color:#8A93A3;margin-top:2px}
        #mp-lobby .pop{margin-left:auto;text-align:right;font-size:11.5px;color:#8A93A3;white-space:nowrap}
        #mp-lobby .pop b{display:block;color:#E7EAF0;font-size:15px}
        #mp-lobby input{width:100%;background:#11151C;border:1px solid #232A35;border-radius:8px;
          padding:10px 12px;color:#E7EAF0;font:inherit;font-size:13px;margin-bottom:14px}
        #mp-lobby .back{background:none;border:none;color:#8A93A3;font:inherit;font-size:12px;
          cursor:pointer;margin-top:10px;text-decoration:underline}
        #mp-lobby .err{color:#E8722E;font-size:12.5px;margin:10px 0}
      </style>
      <div class="box">
        <h2>DRIFT · online</h2>
        <p class="sub">Pick a server. Each one runs its own field, its own round timer and
          its own bots &mdash; you are drifting alongside whoever else is in there.</p>
        <input id="mp-name" maxlength="16" placeholder="your name" aria-label="your name">
        <div id="mp-list"></div>
        <button class="back" id="mp-solo">&larr; play solo instead</button>
      </div>`
    document.body.appendChild(wrap)

    const nameEl = wrap.querySelector('#mp-name')
    nameEl.value = localStorage.getItem('drift_name') || ''
    wrap.querySelector('#mp-solo').onclick = () => { wrap.remove(); onPick(null) }

    // A name is required before joining, and enforced here rather than defaulted server-
    // side. A room full of "drifter", "drifter", "drifter" is not a multiplayer game — you
    // cannot tell who just took the cluster you were going for, which is most of the point
    // of playing with other people. The server still clamps to 16 chars; this is about the
    // player knowing they have an identity, not about trusting the client.
    const nameOk = () => nameEl.value.trim().length >= 2
    const sync = () => {
      const good = nameOk()
      wrap.querySelectorAll('.row').forEach((b) => {
        b.disabled = !good
        b.style.opacity = good ? '1' : '.4'
        b.style.cursor = good ? 'pointer' : 'not-allowed'
      })
      hint.textContent = good ? '' : 'pick a name to join a server — 2 characters or more'
    }
    const hint = document.createElement('p')
    hint.className = 'err'
    hint.style.cssText = 'color:#8A93A3;margin:-8px 0 12px;font-size:11.5px'
    nameEl.after(hint)
    nameEl.addEventListener('input', sync)
    MP._syncLobby = sync
    setTimeout(() => { if (!nameEl.value) nameEl.focus() }, 30)

    const list = wrap.querySelector('#mp-list')
    list.textContent = 'reading the lobby…'
    MP.fetchServers().then((servers) => {
      list.innerHTML = ''
      servers.forEach((s) => {
        const b = document.createElement('button')
        b.className = 'row'
        b.style.setProperty('--hue', s.hue)
        b.innerHTML = `<span><span class="nm">${s.name}</span>
            <span class="bl">${s.blurb}</span></span>
          <span class="pop"><b>${s.players}</b>${s.players === 1 ? 'player' : 'players'}
            ${s.bots ? `· ${s.bots} bots` : ''}</span>`
        b.onclick = () => {
          if (!nameOk()) { nameEl.focus(); return }
          const n = nameEl.value.trim().slice(0, 16)
          localStorage.setItem('drift_name', n)
          wrap.remove()
          onPick(s.id, n)
        }
        list.appendChild(b)
      })
      sync()          // the buttons only exist now, so this is where the gate takes effect
    }).catch(() => {
      // Honest failure with a way forward, rather than an empty list that looks like
      // "nobody is playing".
      list.innerHTML = '<p class="err">Could not reach the lobby. The game still works solo.</p>'
    })
  }

  /** Draw the other attractors. Called by the game's render loop with its own ctx. */
  MP.draw = function (ctx) {
    if (!MP.connected) return
    for (const o of MP.others) {
      ctx.save()
      ctx.globalAlpha = o.bot ? 0.5 : 0.85
      ctx.beginPath()
      ctx.arc(o.x, o.y, o.bot ? 7 : 10, 0, Math.PI * 2)
      ctx.strokeStyle = o.bot ? 'rgba(160,170,190,.75)' : (o.hue || '#7FC0E4')
      ctx.lineWidth = o.bot ? 1.5 : 2.5
      ctx.stroke()
      // A bot is marked as a bot. Passing them off as people would make the room look
      // busier and would be a lie the player can never check.
      ctx.globalAlpha = o.bot ? 0.4 : 0.75
      ctx.fillStyle = '#C9D2E0'
      ctx.font = '10px ui-monospace,monospace'
      ctx.textAlign = 'center'
      ctx.fillText(o.bot ? o.name + ' ·bot' : o.name, o.x, o.y - 15)
      ctx.restore()
    }
  }

  window.MP = MP
})()
