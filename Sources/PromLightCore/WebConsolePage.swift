import Foundation

enum WebConsolePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <title>PromLight Local Console</title>
      <style>
        :root {
          color-scheme: light;
          --page: #f5f7fb;
          --surface: rgba(255, 255, 255, 0.94);
          --surface-solid: #ffffff;
          --surface-muted: #f1f4f9;
          --ink: #172033;
          --muted: #5d687b;
          --border: #d9e0eb;
          --brand: #335cff;
          --brand-strong: #2347db;
          --brand-soft: #e9eeff;
          --success: #08783e;
          --success-soft: #e5f6ec;
          --warning: #875400;
          --warning-soft: #fff3d6;
          --danger: #b42318;
          --danger-soft: #ffebe9;
          --shadow: 0 18px 45px rgba(35, 48, 74, 0.09);
          --radius: 22px;
          --radius-small: 13px;
        }

        * { box-sizing: border-box; }

        html { scroll-behavior: smooth; }

        body {
          min-width: 280px;
          min-height: 100vh;
          margin: 0;
          color: var(--ink);
          background:
            radial-gradient(circle at 8% -5%, rgba(51, 92, 255, 0.12), transparent 27rem),
            radial-gradient(circle at 100% 10%, rgba(18, 176, 128, 0.10), transparent 25rem),
            var(--page);
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          line-height: 1.5;
          -webkit-font-smoothing: antialiased;
        }

        button, input { font: inherit; }

        button {
          min-height: 44px;
          border: 0;
          cursor: pointer;
        }

        button:disabled { cursor: wait; opacity: 0.66; }

        :focus-visible {
          outline: 3px solid #0a5bd8;
          outline-offset: 3px;
        }

        :focus { scroll-margin: 5rem 0 3rem; }

        .skip-link {
          position: fixed;
          z-index: 100;
          top: 0.75rem;
          left: 0.75rem;
          transform: translateY(-180%);
          padding: 0.7rem 1rem;
          border-radius: 0.6rem;
          color: #ffffff;
          background: #111827;
          font-weight: 750;
          text-decoration: none;
        }

        .skip-link:focus { transform: translateY(0); }

        .shell {
          width: min(1180px, calc(100% - 2rem));
          margin: 0 auto;
        }

        .topbar {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 1rem;
          padding: 1.3rem 0 1rem;
        }

        .brand {
          display: flex;
          align-items: center;
          gap: 0.72rem;
          min-width: 0;
        }

        .brand-mark {
          display: grid;
          width: 42px;
          height: 42px;
          flex: 0 0 42px;
          place-items: center;
          border-radius: 14px;
          color: #ffffff;
          background: linear-gradient(145deg, #4169ff, #2747cf);
          box-shadow: 0 9px 22px rgba(51, 92, 255, 0.27);
          font-size: 1.06rem;
          font-weight: 850;
          letter-spacing: -0.04em;
        }

        .brand-copy { min-width: 0; }

        .brand-copy strong,
        .brand-copy span { display: block; }

        .brand-copy strong {
          font-size: 1rem;
          letter-spacing: -0.015em;
        }

        .brand-copy span {
          overflow: hidden;
          color: var(--muted);
          font-size: 0.78rem;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .privacy-chip,
        .status-pill {
          display: inline-flex;
          align-items: center;
          gap: 0.5rem;
          min-height: 34px;
          padding: 0.38rem 0.74rem;
          border: 1px solid var(--border);
          border-radius: 999px;
          background: var(--surface);
          color: var(--muted);
          font-size: 0.78rem;
          font-weight: 700;
          white-space: nowrap;
        }

        .privacy-chip::before,
        .status-pill::before {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: var(--success);
          content: "";
          box-shadow: 0 0 0 4px var(--success-soft);
        }

        main { padding: 0.55rem 0 2.5rem; }

        .hero {
          position: relative;
          display: grid;
          grid-template-columns: minmax(0, 1.35fr) minmax(280px, 0.65fr);
          gap: 1.5rem;
          overflow: hidden;
          padding: clamp(1.4rem, 4vw, 2.5rem);
          border: 1px solid rgba(255, 255, 255, 0.75);
          border-radius: 28px;
          color: #ffffff;
          background:
            radial-gradient(circle at 88% 10%, rgba(113, 235, 202, 0.22), transparent 15rem),
            linear-gradient(135deg, #182445, #263b75 66%, #1f5670);
          box-shadow: 0 24px 60px rgba(21, 34, 68, 0.2);
        }

        .hero-copy { align-self: center; }

        .eyebrow {
          margin: 0 0 0.7rem;
          color: #bfcaff;
          font-size: 0.75rem;
          font-weight: 800;
          letter-spacing: 0.1em;
          text-transform: uppercase;
        }

        h1, h2, h3, p { margin-top: 0; }

        h1 {
          max-width: 15ch;
          margin-bottom: 0.75rem;
          font-size: clamp(2rem, 5vw, 3.65rem);
          line-height: 1.02;
          letter-spacing: -0.055em;
        }

        .hero-copy > p:last-child {
          max-width: 59ch;
          margin-bottom: 0;
          color: #dce4ff;
          font-size: clamp(0.95rem, 2vw, 1.08rem);
        }

        .device-card {
          align-self: stretch;
          padding: 1.2rem;
          border: 1px solid rgba(255, 255, 255, 0.18);
          border-radius: 20px;
          background: rgba(8, 17, 42, 0.36);
          box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08);
          backdrop-filter: blur(12px);
        }

        .device-heading {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 0.7rem;
          margin-bottom: 1rem;
        }

        .device-heading h2 {
          margin: 0;
          font-size: 0.86rem;
          letter-spacing: 0.02em;
        }

        .status-pill {
          border-color: rgba(255, 255, 255, 0.2);
          color: #dce4ff;
          background: rgba(255, 255, 255, 0.09);
        }

        .status-pill[data-state="offline"]::before {
          background: #f97066;
          box-shadow: 0 0 0 4px rgba(249, 112, 102, 0.18);
        }

        .status-pill[data-state="waiting"]::before {
          background: #fdb022;
          box-shadow: 0 0 0 4px rgba(253, 176, 34, 0.18);
        }

        .device-name {
          overflow-wrap: anywhere;
          margin: 0 0 0.18rem;
          font-size: 1.42rem;
          font-weight: 780;
          letter-spacing: -0.025em;
        }

        .device-serial {
          min-height: 1.35rem;
          margin-bottom: 1.05rem;
          color: #aebce8;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.77rem;
          overflow-wrap: anywhere;
        }

        .device-facts {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: 0.65rem;
          margin: 0;
        }

        .device-facts div {
          min-width: 0;
          padding: 0.73rem;
          border-radius: 12px;
          background: rgba(255, 255, 255, 0.08);
        }

        .device-facts dt {
          margin-bottom: 0.12rem;
          color: #aebce8;
          font-size: 0.7rem;
          font-weight: 750;
          letter-spacing: 0.05em;
          text-transform: uppercase;
        }

        .device-facts dd {
          overflow: hidden;
          margin: 0;
          font-size: 0.91rem;
          font-weight: 680;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .grid {
          display: grid;
          grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
          gap: 1.25rem;
          margin-top: 1.25rem;
        }

        .panel {
          min-width: 0;
          padding: clamp(1.15rem, 3vw, 1.55rem);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          background: var(--surface);
          box-shadow: var(--shadow);
        }

        .panel-wide { grid-column: 1 / -1; }

        .panel-heading {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 1rem;
          margin-bottom: 1.15rem;
        }

        .panel-heading h2 {
          margin-bottom: 0.22rem;
          font-size: 1.18rem;
          letter-spacing: -0.025em;
        }

        .panel-heading p {
          margin-bottom: 0;
          color: var(--muted);
          font-size: 0.86rem;
        }

        fieldset {
          min-width: 0;
          margin: 0;
          padding: 0;
          border: 0;
        }

        legend {
          width: 100%;
          margin-bottom: 0.78rem;
          color: var(--muted);
          font-size: 0.76rem;
          font-weight: 750;
        }

        .light-buttons {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 0.72rem;
        }

        .light-button {
          display: flex;
          min-height: 76px;
          align-items: center;
          justify-content: center;
          gap: 0.58rem;
          padding: 0.8rem;
          border: 1px solid transparent;
          border-radius: 15px;
          font-weight: 800;
          transition: transform 150ms ease, box-shadow 150ms ease;
        }

        .light-button:hover:not(:disabled) {
          transform: translateY(-2px);
          box-shadow: 0 10px 20px rgba(29, 42, 68, 0.13);
        }

        .light-dot {
          width: 13px;
          height: 13px;
          flex: 0 0 13px;
          border: 2px solid currentColor;
          border-radius: 50%;
          background: currentColor;
          box-shadow: inset 0 0 0 2px rgba(255, 255, 255, 0.52);
        }

        .light-red { color: #8f1d18; background: #ffe6e3; border-color: #ffc9c4; }
        .light-yellow { color: #6d4800; background: #fff1c2; border-color: #f4d77c; }
        .light-green { color: #08603a; background: #dcf7e8; border-color: #aee5c5; }

        .command-form label {
          display: block;
          margin-bottom: 0.48rem;
          font-size: 0.8rem;
          font-weight: 760;
        }

        .command-row {
          display: flex;
          gap: 0.65rem;
        }

        .command-row input {
          width: 100%;
          min-width: 0;
          min-height: 46px;
          padding: 0.72rem 0.85rem;
          border: 1px solid #aeb8c8;
          border-radius: 12px;
          color: var(--ink);
          background: var(--surface-solid);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.85rem;
        }

        .command-row input[aria-invalid="true"] { border-color: var(--danger); }

        .primary-button,
        .secondary-button {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          border-radius: 12px;
          font-weight: 770;
          white-space: nowrap;
        }

        .primary-button {
          padding: 0.68rem 1rem;
          color: #ffffff;
          background: var(--brand);
          box-shadow: 0 8px 18px rgba(51, 92, 255, 0.22);
        }

        .primary-button:hover:not(:disabled) { background: var(--brand-strong); }

        .secondary-button {
          min-height: 38px;
          padding: 0.48rem 0.78rem;
          border: 1px solid var(--border);
          color: var(--ink);
          background: var(--surface-solid);
          font-size: 0.78rem;
        }

        .secondary-button:hover:not(:disabled) { background: var(--surface-muted); }

        .field-help,
        .field-error {
          margin: 0.5rem 0 0;
          font-size: 0.76rem;
        }

        .field-help { color: var(--muted); }
        .field-error { min-height: 1.15rem; color: var(--danger); font-weight: 680; }

        code {
          padding: 0.1rem 0.33rem;
          border: 1px solid var(--border);
          border-radius: 5px;
          color: #31415f;
          background: var(--surface-muted);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.9em;
          overflow-wrap: anywhere;
        }

        .setup-layout {
          display: grid;
          grid-template-columns: minmax(0, 1.1fr) minmax(260px, 0.9fr);
          gap: 1rem;
        }

        .steps {
          display: grid;
          gap: 0.72rem;
          margin: 0;
          padding: 0;
          list-style: none;
          counter-reset: setup-step;
        }

        .steps li {
          position: relative;
          min-height: 48px;
          padding: 0.74rem 0.8rem 0.74rem 3.25rem;
          border: 1px solid var(--border);
          border-radius: 13px;
          background: var(--surface-solid);
          counter-increment: setup-step;
        }

        .steps li::before {
          position: absolute;
          top: 0.72rem;
          left: 0.72rem;
          display: grid;
          width: 1.82rem;
          height: 1.82rem;
          place-items: center;
          border-radius: 9px;
          color: var(--brand-strong);
          background: var(--brand-soft);
          content: counter(setup-step);
          font-size: 0.76rem;
          font-weight: 850;
        }

        .steps strong,
        .steps span { display: block; }

        .steps strong { margin-bottom: 0.14rem; font-size: 0.87rem; }
        .steps span { color: var(--muted); font-size: 0.79rem; }

        .setup-command {
          height: 100%;
          padding: 1rem;
          border: 1px solid #ccd7ff;
          border-radius: 15px;
          background: linear-gradient(145deg, #f2f5ff, #f8faff);
        }

        .setup-command h3 { margin-bottom: 0.4rem; font-size: 0.92rem; }
        .setup-command p { margin-bottom: 0.8rem; color: var(--muted); font-size: 0.79rem; }

        .terminal-line {
          display: block;
          overflow-x: auto;
          padding: 0.85rem;
          border: 1px solid #26334d;
          border-radius: 11px;
          color: #e5ecff;
          background: #182238;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.8rem;
          white-space: nowrap;
        }

        .agents {
          display: flex;
          flex-wrap: wrap;
          gap: 0.42rem;
          margin-top: 0.8rem;
        }

        .agents span {
          padding: 0.28rem 0.52rem;
          border: 1px solid #d5dcf6;
          border-radius: 999px;
          color: #3d4e76;
          background: #ffffff;
          font-size: 0.69rem;
          font-weight: 720;
        }

        .event-list {
          display: grid;
          max-height: 360px;
          gap: 0.55rem;
          overflow-y: auto;
          margin: 0;
          padding: 0 0.2rem 0 0;
          list-style: none;
          scrollbar-gutter: stable;
        }

        .event-item {
          display: grid;
          grid-template-columns: auto minmax(0, 1fr) auto;
          align-items: start;
          gap: 0.7rem;
          padding: 0.72rem 0.8rem;
          border: 1px solid var(--border);
          border-radius: 12px;
          background: var(--surface-solid);
        }

        .event-marker {
          width: 9px;
          height: 9px;
          margin-top: 0.36rem;
          border-radius: 50%;
          background: #5372d8;
          box-shadow: 0 0 0 4px #e8edff;
        }

        .event-item[data-kind="success"] .event-marker { background: var(--success); box-shadow: 0 0 0 4px var(--success-soft); }
        .event-item[data-kind="warning"] .event-marker { background: var(--warning); box-shadow: 0 0 0 4px var(--warning-soft); }
        .event-item[data-kind="error"] .event-marker { background: var(--danger); box-shadow: 0 0 0 4px var(--danger-soft); }

        .event-copy { min-width: 0; }
        .event-copy strong { display: block; margin-bottom: 0.1rem; font-size: 0.79rem; }
        .event-copy span { display: block; color: var(--muted); font-size: 0.8rem; overflow-wrap: anywhere; }
        .event-item time { color: var(--muted); font-size: 0.7rem; white-space: nowrap; }

        .empty-state {
          padding: 1.6rem;
          border: 1px dashed #b8c2d2;
          border-radius: 13px;
          color: var(--muted);
          background: var(--surface-muted);
          text-align: center;
          font-size: 0.84rem;
        }

        .service-message {
          margin: 1rem 0 0;
          color: var(--muted);
          font-size: 0.75rem;
          text-align: center;
        }

        .visually-hidden {
          position: absolute;
          width: 1px;
          height: 1px;
          margin: -1px;
          padding: 0;
          overflow: hidden;
          clip: rect(0, 0, 0, 0);
          white-space: nowrap;
          border: 0;
        }

        @media (max-width: 820px) {
          .hero { grid-template-columns: 1fr; }
          .grid { grid-template-columns: 1fr; }
          .panel-wide { grid-column: auto; }
          .setup-layout { grid-template-columns: 1fr; }
        }

        @media (max-width: 560px) {
          .shell { width: min(100% - 1rem, 1180px); }
          .topbar { padding-top: 0.8rem; }
          .privacy-chip span { display: none; }
          .privacy-chip::after { content: "Local"; }
          .hero { padding: 1.25rem; border-radius: 21px; }
          h1 { font-size: 2.2rem; }
          .light-buttons { grid-template-columns: 1fr; }
          .device-facts { grid-template-columns: 1fr; }
          .light-button { min-height: 56px; }
          .command-row { align-items: stretch; flex-direction: column; }
          .command-row .primary-button { width: 100%; }
          .event-item { grid-template-columns: auto minmax(0, 1fr); }
          .event-item time { grid-column: 2; }
        }

        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after {
            scroll-behavior: auto !important;
            transition-duration: 0.01ms !important;
          }
        }

        @media (prefers-color-scheme: dark) {
          :root {
            color-scheme: dark;
            --page: #101522;
            --surface: rgba(24, 31, 47, 0.95);
            --surface-solid: #1b2333;
            --surface-muted: #222b3c;
            --ink: #f0f3fa;
            --muted: #aab4c6;
            --border: #354055;
            --brand: #6f8cff;
            --brand-strong: #86a0ff;
            --brand-soft: #283868;
            --success: #57d38b;
            --success-soft: #1b4631;
            --warning: #ffc65c;
            --warning-soft: #523c17;
            --danger: #ff827a;
            --danger-soft: #522a2b;
            --shadow: 0 18px 45px rgba(0, 0, 0, 0.24);
          }

          code { color: #d7e0f5; }
          .light-red { color: #ffc1bc; background: #542925; border-color: #75413c; }
          .light-yellow { color: #ffe09a; background: #504019; border-color: #75612c; }
          .light-green { color: #abebc7; background: #1e4934; border-color: #2d6b4c; }
          .setup-command { border-color: #3b4a78; background: linear-gradient(145deg, #202a49, #1c263d); }
          .agents span { color: #ced8f6; background: #242e46; border-color: #3b4868; }
        }

        @media (forced-colors: active) {
          .light-dot, .event-marker, .privacy-chip::before, .status-pill::before {
            border: 2px solid ButtonText;
            box-shadow: none;
          }
        }
      </style>
    </head>
    <body>
      <a class="skip-link" href="#main-content">Skip to main content</a>

      <header class="shell topbar">
        <div class="brand" aria-label="PromLight Local Console">
          <span class="brand-mark" aria-hidden="true">PL</span>
          <span class="brand-copy">
            <strong>PromLight</strong>
            <span>Local setup and control console</span>
          </span>
        </div>
        <div class="privacy-chip" title="This server is available only on this Mac">
          <span>Private to this Mac</span>
        </div>
      </header>

      <main class="shell" id="main-content" tabindex="-1">
        <section class="hero" aria-labelledby="page-title">
          <div class="hero-copy">
            <p class="eyebrow">Local device control</p>
            <h1 id="page-title">Your work, visible at a glance.</h1>
            <p>Check the connected PromLight, choose a signal, and confirm that your AI agent events are arriving—all from one private local page.</p>
          </div>

          <section class="device-card" aria-labelledby="device-heading">
            <div class="device-heading">
              <h2 id="device-heading">Connected device</h2>
              <span class="status-pill" id="connection-pill" data-state="waiting">
                <span id="connection-label">Checking</span>
              </span>
            </div>
            <p class="device-name" id="device-name">Looking for PromLight…</p>
            <p class="device-serial" id="device-serial">Please wait</p>
            <dl class="device-facts">
              <div>
                <dt>Light state</dt>
                <dd id="light-state">Unknown</dd>
              </div>
              <div>
                <dt>Active agent</dt>
                <dd id="active-agent">None</dd>
              </div>
              <div>
                <dt>Battery</dt>
                <dd id="battery-level">Unavailable</dd>
              </div>
            </dl>
          </section>
        </section>

        <div class="grid">
          <section class="panel" aria-labelledby="quick-controls-heading">
            <div class="panel-heading">
              <div>
                <h2 id="quick-controls-heading">Quick light controls</h2>
                <p>Set a clear, steady status signal.</p>
              </div>
            </div>
            <fieldset>
              <legend>Choose the light color</legend>
              <div class="light-buttons">
                <button class="light-button light-red" type="button" data-command="led red on --only" data-label="red">
                  <span class="light-dot" aria-hidden="true"></span>
                  Red
                </button>
                <button class="light-button light-yellow" type="button" data-command="led yellow on --only" data-label="yellow">
                  <span class="light-dot" aria-hidden="true"></span>
                  Yellow
                </button>
                <button class="light-button light-green" type="button" data-command="led green on --only" data-label="green">
                  <span class="light-dot" aria-hidden="true"></span>
                  Green
                </button>
              </div>
            </fieldset>
          </section>

          <section class="panel" aria-labelledby="command-heading">
            <div class="panel-heading">
              <div>
                <h2 id="command-heading">Command console</h2>
                <p>Send a supported PromLight command or script.</p>
              </div>
            </div>
            <form class="command-form" id="command-form" novalidate>
              <label for="command-input">Light command</label>
              <div class="command-row">
                <input id="command-input" name="command" type="text" autocomplete="off" spellcheck="false" aria-describedby="command-help command-error" placeholder="led yellow blink --only">
                <button class="primary-button" id="command-submit" type="submit">Run command</button>
              </div>
              <p class="field-help" id="command-help">Example: <code>led all blink --count 2</code></p>
              <p class="field-error" id="command-error" role="alert"></p>
            </form>
          </section>

          <section class="panel panel-wide" aria-labelledby="setup-heading">
            <div class="panel-heading">
              <div>
                <h2 id="setup-heading">AI agent setup</h2>
                <p>Connect supported coding agents so their work states appear on PromLight.</p>
              </div>
            </div>
            <div class="setup-layout">
              <ol class="steps">
                <li>
                  <strong>Keep PromLight running</strong>
                  <span>Connect the device and leave the PromLight background service active.</span>
                </li>
                <li>
                  <strong>Install the agent hooks</strong>
                  <span>Run the setup command in Terminal for your preferred AI agent.</span>
                </li>
                <li>
                  <strong>Restart the agent</strong>
                  <span>Open a new agent session and submit a prompt to confirm the event appears below.</span>
                </li>
              </ol>
              <aside class="setup-command" aria-label="Agent setup command">
                <h3>Start with Codex</h3>
                <p>Run the executable inside the installed app. Replace <code>codex</code> with another supported agent name when needed.</p>
                <code class="terminal-line">'/Applications/PromLight.app/Contents/MacOS/PromLight' setup codex</code>
                <div class="agents" aria-label="Supported agents">
                  <span>Claude Code</span><span>Codex</span><span>Cursor</span><span>Copilot</span><span>Qoder</span><span>CodeBuddy</span><span>Antigravity</span>
                </div>
              </aside>
            </div>
          </section>

          <section class="panel panel-wide" aria-labelledby="events-heading">
            <div class="panel-heading">
              <div>
                <h2 id="events-heading">Event log</h2>
                <p>Recent device actions and AI agent activity.</p>
              </div>
              <button class="secondary-button" id="refresh-button" type="button">Refresh</button>
            </div>
            <ol class="event-list" id="event-list" aria-label="Recent PromLight events">
              <li class="empty-state">No events yet. Run a light command or start an AI agent session.</li>
            </ol>
          </section>
        </div>

        <p class="service-message" id="service-message">This console listens only on 127.0.0.1:7800.</p>
      </main>

      <div class="visually-hidden" id="polite-announcer" aria-live="polite" aria-atomic="true"></div>

      <script>
        (() => {
          "use strict";

          const elements = {
            connectionPill: document.getElementById("connection-pill"),
            connectionLabel: document.getElementById("connection-label"),
            deviceName: document.getElementById("device-name"),
            deviceSerial: document.getElementById("device-serial"),
            lightState: document.getElementById("light-state"),
            activeAgent: document.getElementById("active-agent"),
            batteryLevel: document.getElementById("battery-level"),
            serviceMessage: document.getElementById("service-message"),
            eventList: document.getElementById("event-list"),
            refreshButton: document.getElementById("refresh-button"),
            commandForm: document.getElementById("command-form"),
            commandInput: document.getElementById("command-input"),
            commandSubmit: document.getElementById("command-submit"),
            commandError: document.getElementById("command-error"),
            announcer: document.getElementById("polite-announcer")
          };

          let localEvents = [];
          let serverEvents = [];
          let refreshInProgress = false;
          let statusWasUnavailable = false;

          function announce(message) {
            elements.announcer.textContent = "";
            window.requestAnimationFrame(() => { elements.announcer.textContent = message; });
          }

          function setConnection(connected, label) {
            elements.connectionPill.dataset.state = connected ? "online" : "offline";
            elements.connectionLabel.textContent = label;
          }

          function appendLocalEvent(kind, source, message) {
            localEvents.unshift({
              timestamp: new Date().toISOString(),
              kind,
              source,
              message
            });
            localEvents = localEvents.slice(0, 30);
            renderEvents();
          }

          function formatTime(value) {
            const date = new Date(value);
            if (Number.isNaN(date.getTime())) return "Now";
            return new Intl.DateTimeFormat(undefined, {
              hour: "2-digit",
              minute: "2-digit",
              second: "2-digit"
            }).format(date);
          }

          function renderEvents() {
            const events = [...localEvents, ...serverEvents]
              .filter(event => event && event.message)
              .sort((a, b) => new Date(b.timestamp || 0) - new Date(a.timestamp || 0))
              .slice(0, 50);

            if (events.length === 0) {
              const empty = document.createElement("li");
              empty.className = "empty-state";
              empty.textContent = "No events yet. Run a light command or start an AI agent session.";
              elements.eventList.replaceChildren(empty);
              return;
            }

            const items = events.map(event => {
              const item = document.createElement("li");
              item.className = "event-item";
              item.dataset.kind = ["success", "warning", "error"].includes(event.kind) ? event.kind : "info";

              const marker = document.createElement("span");
              marker.className = "event-marker";
              marker.setAttribute("aria-hidden", "true");

              const copy = document.createElement("span");
              copy.className = "event-copy";
              const source = document.createElement("strong");
              source.textContent = event.source || "PromLight";
              const message = document.createElement("span");
              message.textContent = event.message;
              copy.append(source, message);

              const time = document.createElement("time");
              time.dateTime = event.timestamp || "";
              time.textContent = formatTime(event.timestamp);

              item.append(marker, copy, time);
              return item;
            });
            elements.eventList.replaceChildren(...items);
          }

          async function readJSON(response) {
            try { return await response.json(); }
            catch { return {}; }
          }

          async function refreshStatus({ announceResult = false } = {}) {
            if (refreshInProgress) return;
            refreshInProgress = true;
            elements.refreshButton.disabled = true;
            try {
              const response = await fetch("/api/status", {
                method: "GET",
                headers: { "Accept": "application/json" },
                cache: "no-store"
              });
              const status = await readJSON(response);
              if (!response.ok) throw new Error(status.error || "Status is unavailable.");

              setConnection(Boolean(status.connected), status.connected ? "Connected" : "Not connected");
              elements.deviceName.textContent = status.deviceName || (status.connected ? "PromLight device" : "No PromLight found");
              elements.deviceSerial.textContent = status.serialNumber ? `Serial ${status.serialNumber}` : (status.connected ? "Serial number unavailable" : "Connect a device to begin");
              elements.lightState.textContent = status.lightState || "Unknown";
              elements.activeAgent.textContent = status.activeAgent || "None";
              elements.batteryLevel.textContent = Number.isInteger(status.batteryLevel) && status.batteryLevel >= 0 && status.batteryLevel <= 100
                ? `${status.batteryLevel}%`
                : "Unavailable";
              elements.serviceMessage.textContent = status.serviceMessage || "This console listens only on 127.0.0.1:7800.";
              serverEvents = Array.isArray(status.recentEvents) ? status.recentEvents : [];
              renderEvents();

              if (statusWasUnavailable) appendLocalEvent("success", "Console", "The local service is available again.");
              statusWasUnavailable = false;
              if (announceResult) announce("Status refreshed.");
            } catch (error) {
              setConnection(false, "Unavailable");
              elements.deviceName.textContent = "Local service unavailable";
              elements.deviceSerial.textContent = "Check that PromLight is running";
              elements.lightState.textContent = "Unknown";
              elements.activeAgent.textContent = "None";
              elements.batteryLevel.textContent = "Unavailable";
              if (!statusWasUnavailable) appendLocalEvent("error", "Console", error.message || "Could not read device status.");
              statusWasUnavailable = true;
              if (announceResult) announce("Status refresh failed.");
            } finally {
              refreshInProgress = false;
              elements.refreshButton.disabled = false;
            }
          }

          async function runCommand(command, trigger, successMessage) {
            trigger.disabled = true;
            trigger.setAttribute("aria-busy", "true");
            try {
              const response = await fetch("/api/command", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Accept": "application/json" },
                body: JSON.stringify({ command })
              });
              const result = await readJSON(response);
              if (!response.ok || result.accepted === false) {
                throw new Error(result.error || result.message || "The command was not accepted.");
              }
              const message = result.message || successMessage;
              appendLocalEvent("success", "Light control", message);
              announce(message);
              await refreshStatus();
              return true;
            } catch (error) {
              const message = error.message || "The command failed.";
              appendLocalEvent("error", "Light control", message);
              announce(message);
              return false;
            } finally {
              trigger.disabled = false;
              trigger.removeAttribute("aria-busy");
            }
          }

          document.querySelectorAll("[data-command]").forEach(button => {
            button.addEventListener("click", () => {
              const color = button.dataset.label || "selected";
              runCommand(button.dataset.command, button, `The light is now ${color}.`);
            });
          });

          elements.commandForm.addEventListener("submit", async event => {
            event.preventDefault();
            const command = elements.commandInput.value.trim();
            elements.commandError.textContent = "";
            elements.commandInput.setAttribute("aria-invalid", "false");

            if (!command) {
              elements.commandInput.setAttribute("aria-invalid", "true");
              elements.commandError.textContent = "Enter a command before running it.";
              elements.commandInput.focus();
              return;
            }

            const succeeded = await runCommand(command, elements.commandSubmit, "Command completed.");
            if (!succeeded) {
              elements.commandInput.setAttribute("aria-invalid", "true");
              elements.commandError.textContent = "The command could not be completed. Review the event log for details.";
            }
          });

          elements.commandInput.addEventListener("input", () => {
            if (elements.commandInput.value.trim()) {
              elements.commandInput.setAttribute("aria-invalid", "false");
              elements.commandError.textContent = "";
            }
          });

          elements.refreshButton.addEventListener("click", () => refreshStatus({ announceResult: true }));

          refreshStatus();
          window.setInterval(refreshStatus, 3000);
        })();
      </script>
    </body>
    </html>
    """#
}
