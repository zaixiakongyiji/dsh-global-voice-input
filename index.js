import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import process from 'node:process'
import z from '@deepseek-ai/schemastery'

const REMOTE_METHODS = '@deepseek-ai/dsh-typert-protocol/remote-methods'

export const Config = z.object({
  enabled: z.boolean().default(true).volatile(),
  hotkey: z.string().min(1).default('Ctrl+Alt+Space').volatile(),
  silenceMs: z.natural().min(300).max(5000).default(1200).volatile(),
  maxDurationMs: z.natural().min(5000).max(300000).default(60000).volatile(),
  autoSubmit: z.boolean().default(true).volatile(),
  showOverlay: z.boolean().default(true).volatile(),
  showReplyPreview: z.boolean().default(true).volatile()
})

class Subscriber {
  constructor() {
    this.items = []
    this.waiters = []
    this.closed = false
  }

  push(value) {
    if (this.closed) return
    const waiter = this.waiters.shift()
    if (waiter) waiter({ value, done: false })
    else this.items.push(value)
  }

  close() {
    if (this.closed) return
    this.closed = true
    for (const waiter of this.waiters.splice(0)) waiter({ value: undefined, done: true })
  }

  next(signal) {
    if (this.items.length) return Promise.resolve({ value: this.items.shift(), done: false })
    if (this.closed || signal?.aborted) return Promise.resolve({ value: undefined, done: true })
    return new Promise((resolve) => {
      const waiter = (result) => {
        signal?.removeEventListener('abort', onAbort)
        resolve(result)
      }
      const onAbort = () => {
        signal?.removeEventListener('abort', onAbort)
        const index = this.waiters.indexOf(waiter)
        if (index >= 0) this.waiters.splice(index, 1)
        resolve({ value: undefined, done: true })
      }
      if (signal) signal.addEventListener('abort', onAbort, { once: true })
      this.waiters.push(waiter)
    })
  }
}

function parseHotkey(value) {
  const parts = String(value).split('+').map((part) => part.trim().toLowerCase()).filter(Boolean)
  let modifiers = []
  let key = ''
  for (const part of parts) {
    if (part === 'ctrl' || part === 'control') modifiers.push('Ctrl')
    else if (part === 'alt') modifiers.push('Alt')
    else if (part === 'shift') modifiers.push('Shift')
    else if (part === 'win' || part === 'windows' || part === 'meta') modifiers.push('Win')
    else key = part.length === 1 ? part.toUpperCase() : part[0].toUpperCase() + part.slice(1)
  }
  if (!key) throw new Error(`Invalid global hotkey: ${value}`)
  return [...new Set(modifiers), key].join('+')
}

class GlobalVoiceController {
  constructor(ctx, config = {}) {
    this.ctx = ctx
    this.name = 'globalVoiceController'
    // Volatile schema fields are references, not primitive values. Resolve
    // them on every read so live settings edits reach the running helpers.
    this.config = new Proxy(config, {
      get(target, key) {
        const value = target[key]
        return value && typeof value.get === 'function' ? value.get() : value
      }
    })
    this.subscribers = new Set()
    this.child = undefined
    this.overlay = undefined
    this.overlayStopping = false
    this.overlayStateRevision = -1
    this.stopping = false
    this.hotkey = parseHotkey(this.config.hotkey ?? 'Ctrl+Alt+Space')
    this.typertRemote = { service: this, serviceKey: this.name, namespace: 'globalVoice' }
    ctx.on('loader/volatile-update', () => this.updateConfig())
    ctx.effect(() => {
      if (this.config.enabled !== false && process.platform === 'win32') this.start()
      else if (process.platform !== 'win32') this.publish({ type: 'error', code: 'unsupported-platform', message: 'Global voice input requires Windows.' })
      else this.publish({ type: 'stopped', reason: 'disabled' })
      return () => this.stop()
    }, 'global-voice-input.helper')
  }

  publish(event) {
    for (const subscriber of this.subscribers) subscriber.push(event)
  }

  settingsEvent() {
    return {
      type: 'ready',
      hotkey: this.hotkey,
      platform: process.platform,
      silenceMs: this.config.silenceMs,
      maxDurationMs: this.config.maxDurationMs,
      autoSubmit: this.config.autoSubmit !== false,
      showOverlay: this.config.showOverlay !== false,
      showReplyPreview: this.config.showReplyPreview !== false
    }
  }

  updateConfig() {
    const enabled = this.config.enabled !== false && process.platform === 'win32'
    const nextHotkey = parseHotkey(this.config.hotkey)
    const hotkeyChanged = nextHotkey !== this.hotkey
    this.hotkey = nextHotkey
    if (!enabled) {
      if (this.child) {
        this.stopping = true
        this.child.kill()
        this.child = undefined
      }
      this.stopOverlay()
      this.publish({ type: 'stopped', reason: 'disabled' })
    } else if (this.config.showOverlay === false) {
      this.stopOverlay()
      if (!this.child || hotkeyChanged) {
        if (this.child) {
          this.stopping = true
          this.child.kill()
          this.child = undefined
        }
        this.stopping = false
        this.start()
      }
    } else if (!this.child || hotkeyChanged || !this.overlay) {
      if (this.child) {
        this.stopping = true
        this.child.kill()
        this.child = undefined
      }
      this.stopping = false
      this.start()
    }
    this.publish(this.settingsEvent())
  }

  start() {
    if (this.child || this.stopping) return
    const script = fileURLToPath(new URL('./native/global-hotkey.ps1', import.meta.url))
    const child = spawn('powershell.exe', [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', script, '-ParentPid', String(process.pid), '-Hotkey', this.hotkey
    ], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
    this.child = child
    const lines = createInterface({ input: child.stdout })
    lines.on('line', (line) => {
      try {
        const value = JSON.parse(line)
        if (value.type === 'trigger') {
          value.id ??= randomUUID()
          // Give the native capsule immediate feedback even if the browser
          // Remote stream is busy opening or rendering the current Session.
          this.reportState({ phase: 'requesting', message: '', revision: this.overlayStateRevision + 0.5 })
        }
        if (value.type === 'ready') value.hotkey = this.hotkey
        if (value.type === 'error') this.reportState({ phase: 'feedback', message: value.message || 'Global shortcut unavailable.' })
        this.publish(value)
      } catch {
        this.publish({ type: 'error', code: 'helper-output', message: 'The global shortcut helper returned invalid data.' })
      }
    })
    child.on('error', (error) => {
      if (!this.stopping) {
        this.publish({ type: 'error', code: 'helper-start', message: error.message })
        this.reportState({ phase: 'feedback', message: error.message })
      }
    })
    child.on('exit', (code) => {
      if (this.child !== child) return
      this.child = undefined
      if (!this.stopping) {
        const message = `Global shortcut helper exited (${code ?? 'unknown'}).`
        this.publish({ type: 'error', code: 'helper-exit', message })
        this.reportState({ phase: 'feedback', message })
      }
    })
    if (this.config.showOverlay !== false) this.startOverlay()
  }

  startOverlay() {
    if (this.overlay || this.overlayStopping || process.platform !== 'win32') return
    const script = fileURLToPath(new URL('./native/desktop-overlay.ps1', import.meta.url))
    const overlay = spawn('powershell.exe', [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
      '-File', script, '-ParentPid', String(process.pid)
    ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
    this.overlay = overlay
    let diagnostic = ''
    overlay.stderr.setEncoding('utf8')
    overlay.stderr.on('data', (text) => { diagnostic = (diagnostic + text).slice(-4000) })
    overlay.stdin.on('error', (error) => {
      if (this.overlay === overlay) this.publish({ type: 'error', code: 'overlay-pipe', message: error.message })
    })
    const lines = createInterface({ input: overlay.stdout })
    lines.on('line', (line) => {
      try {
        const value = JSON.parse(line)
        if (value.type === 'action') this.publish({ type: 'overlay-action', action: value.action, text: value.text })
      } catch {
        this.publish({ type: 'error', code: 'overlay-output', message: 'The desktop overlay returned invalid data.' })
      }
    })
    overlay.on('error', (error) => {
      if (!this.overlayStopping) this.publish({ type: 'error', code: 'overlay-start', message: error.message })
    })
    overlay.on('exit', (code) => {
      if (this.overlay !== overlay) return
      this.overlay = undefined
      if (!this.overlayStopping) {
        const message = `Desktop overlay exited (${code ?? 'unknown'}). ${diagnostic.trim()}`
        this.ctx.logger?.('global-voice-input').warn(message)
        this.publish({ type: 'error', code: 'overlay-exit', message })
      }
    })
    this.reportState({ phase: 'idle' })
  }

  // DSH's SRC Remote reflection requires bare parameter names.
  // Defaults in the signature reject the call before this method runs.
  reportState(state) {
    state ??= {}
    if (!this.overlay || this.overlay.killed || this.config.showOverlay === false) return false
    const revision = Number(state.revision)
    if (Number.isFinite(revision)) {
      if (revision < this.overlayStateRevision) return false
      this.overlayStateRevision = revision
    }
    try {
      this.overlay.stdin.write(`${JSON.stringify({ type: 'state', ...state })}\n`)
    } catch {}
    return true
  }

  stopOverlay() {
    this.overlayStopping = true
    if (this.overlay) {
      this.overlay.stdin.end()
      this.overlay.kill()
      this.overlay = undefined
    }
    this.overlayStopping = false
  }

  stop() {
    this.stopping = true
    if (this.child) {
      this.child.kill()
      this.child = undefined
    }
    this.stopOverlay()
    this.publish({ type: 'stopped', reason: 'plugin-disposed' })
    for (const subscriber of this.subscribers) subscriber.close()
    this.subscribers.clear()
  }

  async *follow(signal) {
    signal.throwIfAborted()
    const subscriber = new Subscriber()
    this.subscribers.add(subscriber)
      subscriber.push(this.settingsEvent())
    try {
      while (!signal.aborted) {
        const item = await subscriber.next(signal)
        if (item.done) return
        yield item.value
      }
    } finally {
      this.subscribers.delete(subscriber)
      subscriber.close()
    }
  }
}

Object.defineProperty(GlobalVoiceController.prototype, REMOTE_METHODS, {
  configurable: true,
  value: Object.freeze({
    version: 1,
    methods: Object.freeze([Object.freeze({
      method: 'follow',
      mode: 'stream',
      invocation: Object.freeze({ kind: 'direct' })
    }), Object.freeze({
      method: 'reportState',
      invocation: Object.freeze({ kind: 'direct' })
    })])
  })
})

export function apply(ctx, config) {
  const controller = new GlobalVoiceController(ctx, config)
  const dispose = ctx.provide('globalVoiceController', controller)
  return async () => {
    await controller.stop()
    await dispose?.()
  }
}

export const inject = []

export { GlobalVoiceController }


