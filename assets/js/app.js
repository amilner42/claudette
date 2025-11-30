// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "../../deps/phoenix_html/priv/static/phoenix_html.js"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "../../deps/phoenix/priv/static/phoenix.mjs"
import {LiveSocket} from "../../deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js"
import topbar from "../vendor/topbar"

// xterm.js for terminal
import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { WebLinksAddon } from "@xterm/addon-web-links"

// Hooks
let Hooks = {}

Hooks.Clipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const content = this.el.dataset.content
      navigator.clipboard.writeText(content).then(() => {
        const originalText = this.el.innerText
        this.el.innerText = "Copied!"
        setTimeout(() => {
          this.el.innerText = originalText
        }, 1500)
      })
    })
  }
}

Hooks.Terminal = {
  mounted() {
    // Create terminal instance
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: '"JetBrains Mono", "Fira Code", Menlo, Monaco, "Courier New", monospace',
      theme: {
        background: '#0a0a0f',
        foreground: '#e4e4e7',
        cursor: '#a5b4fc',
        cursorAccent: '#0a0a0f',
        selectionBackground: '#3f3f46',
        black: '#18181b',
        red: '#f87171',
        green: '#4ade80',
        yellow: '#facc15',
        blue: '#60a5fa',
        magenta: '#c084fc',
        cyan: '#22d3ee',
        white: '#e4e4e7',
        brightBlack: '#52525b',
        brightRed: '#fca5a5',
        brightGreen: '#86efac',
        brightYellow: '#fde047',
        brightBlue: '#93c5fd',
        brightMagenta: '#d8b4fe',
        brightCyan: '#67e8f9',
        brightWhite: '#fafafa'
      }
    })

    // Add addons
    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.loadAddon(new WebLinksAddon())

    // Open terminal in container
    this.term.open(this.el)
    this.fitAddon.fit()

    // Send resize info to server
    this.pushEvent("terminal:resize", {
      rows: this.term.rows,
      cols: this.term.cols
    })

    // Handle user input
    this.term.onData((data) => {
      this.pushEvent("terminal:input", { data: btoa(data) })
    })

    // Handle terminal output from server
    this.handleEvent("terminal:output", ({ data }) => {
      try {
        const decoded = atob(data)
        this.term.write(decoded)
      } catch (e) {
        this.term.write(data)
      }
    })

    // Handle terminal clear (when switching workspaces)
    this.handleEvent("terminal:clear", () => {
      this.term.clear()
      this.term.reset()
    })

    // Handle window resize
    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
      this.pushEvent("terminal:resize", {
        rows: this.term.rows,
        cols: this.term.cols
      })
    })
    this.resizeObserver.observe(this.el)

    // Focus terminal
    this.term.focus()
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    if (this.term) {
      this.term.dispose()
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Handle clipboard copy events from LiveView
window.addEventListener("phx:copy-to-clipboard", (e) => {
  navigator.clipboard.writeText(e.detail.text).then(() => {
    // Could show a toast notification here if desired
    console.log("Copied to clipboard:", e.detail.text)
  }).catch(err => {
    console.error("Failed to copy:", err)
  })
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

