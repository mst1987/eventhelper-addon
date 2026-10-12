"use strict";

/**
 * The hand-over after a self-update: the new .exe has replaced the old one on
 * disk, now the old process steps aside and the new one takes over.
 *
 * Order matters:
 *   1. stop the upload (runner) and the update timers - two instances must
 *      never upload the same file in parallel;
 *   2. unregister from lib/instance.js - otherwise the new .exe finds this
 *      instance and only re-opens its window, then exits;
 *   3. start the new .exe (detached) and wait until it has registered itself
 *      (it answers on its own UI port; this one stays up and keeps serving the
 *      "Starte neu ..." state meanwhile, so the page never shows a dead end);
 *   4. only then close the UI server and exit. The frameless window
 *      (EventHelperSyncWindow.exe) watches its parent process and closes with
 *      it; the new instance opens its own window from
 *      %LOCALAPPDATA%\EventHelperSync\host\<version>.
 *
 * If the new instance never comes up (spawn error, crash at start), the old
 * one resumes: runner and timers restart, it registers again and the update
 * strip shows the error with "Erneut versuchen" / manual download.
 */

const DEFAULT_WAIT_MS = 20 * 1000;
const DEFAULT_POLL_MS = 250;

const sleepMs = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * @param {object} deps
 * @param {{ stop: Function, start: Function }} deps.runner
 * @param {{ stop: Function, start: Function, failRestart: Function }} deps.updater
 * @param {{ stop: Function, url?: string }|null} deps.ui
 * @param {{ unregister: Function, register: Function, findRunningEntry: Function }} deps.instance
 * @param {(exePath: string) => Promise<{ ok: boolean, error?: string }>} deps.relaunch
 * @param {string} deps.exePath
 * @param {(code: number) => void} deps.exit
 * @param {(text: string) => void} [deps.notify]  a visible message (the .exe has no console)
 * @param {(level: string, text: string) => void} [deps.log]
 * @returns {Promise<boolean>}  true: the new instance runs and this one exits
 */
async function handOver({
    runner, updater, ui, instance, relaunch, exePath, exit,
    notify = () => {}, log = () => {},
    waitMs = DEFAULT_WAIT_MS, pollMs = DEFAULT_POLL_MS, sleep = sleepMs,
}) {
    runner.stop();
    updater.stop();
    instance.unregister();

    const started = await relaunch(exePath);
    let up = !!started.ok;
    let reason = started.ok ? "" : `Start fehlgeschlagen (${started.error})`;
    if (up) {
        up = false;
        for (let waited = 0; waited <= waitMs; waited += pollMs) {
            const entry = await instance.findRunningEntry({ timeoutMs: 1000 });
            if (entry) {
                up = true;
                break;
            }
            await sleep(pollMs);
        }
        if (!up) reason = `Die neue Version meldete sich nicht innerhalb von ${Math.round(waitMs / 1000)} s`;
    }

    if (up) {
        if (ui) ui.stop();
        exit(0);
        return true;
    }

    // Take over again: this process still has the (old) code and the window.
    const message = `Neustart hat nicht geklappt: ${reason}. Bitte EventHelperSync.exe von Hand starten.`;
    log("error", message);
    updater.failRestart(message);
    if (ui && ui.url) instance.register(ui.url);
    runner.start();
    updater.start();
    notify(message);
    return false;
}

module.exports = { handOver, DEFAULT_WAIT_MS };
