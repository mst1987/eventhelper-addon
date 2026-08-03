"use strict";

/**
 * Den Envelope aus den SavedVariables lesen und hochladen.
 *
 * Hochgeladen wird eine Session pro Anfrage. Der Server nimmt zwar mehrere
 * gleichzeitig, aber sein Body-Limit liegt bei 1 MB, und ein Payload, der es
 * reisst, käme als "kein EventHelper-Export" zurück statt als "zu gross" —
 * einzeln hochzuladen macht die Grenze zu einem Nicht-Thema und die
 * Fehlermeldung pro Raid-Abend eindeutig.
 */
const fs = require("fs");
const { parseSavedVariables } = require("./luaParser");

const SYNC_VERSION = require("../package.json").version;

class UploadError extends Error {
    constructor(message, status) {
        super(message);
        this.name = "UploadError";
        this.status = status;
    }
}

/**
 * Den Envelope aus einer SavedVariables-Datei holen.
 * @returns {object|null} null, wenn das Addon noch nichts geschrieben hat
 */
function readEnvelope(file) {
    const text = fs.readFileSync(file, "utf8");
    const globals = parseSavedVariables(text);
    const db = globals.EventHelperSyncDB;
    if (!db || typeof db !== "object") return null;
    const envelope = db.export;
    if (!envelope || typeof envelope !== "object" || !envelope.format) return null;
    return envelope;
}

/**
 * Ein Envelope, der genau eine Session enthält — die Form, in der wirklich
 * hochgeladen wird.
 */
function envelopeForSession(envelope, session) {
    return {
        ...envelope,
        client: { ...(envelope.client || {}), sync: SYNC_VERSION },
        sessions: [session],
    };
}

async function postSession(config, payload) {
    const url = `${String(config.baseUrl).replace(/\/+$/, "")}/api/ingest/loot`;
    let res;
    try {
        res = await fetch(url, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Authorization: `Bearer ${config.token}`,
            },
            body: JSON.stringify(payload),
        });
    } catch (e) {
        throw new UploadError(`${url} nicht erreichbar: ${e.message}`);
    }

    const text = await res.text();
    let body;
    try {
        body = JSON.parse(text);
    } catch {
        throw new UploadError(`Unerwartete Antwort (HTTP ${res.status}): ${text.slice(0, 200)}`, res.status);
    }
    if (!res.ok) {
        const err = body && body.error;
        throw new UploadError(err ? err.message : `HTTP ${res.status}`, res.status);
    }
    return (body && body.data) || body;
}

/**
 * Eine SavedVariables-Datei hochladen — ohne die hier abgewählten Abende.
 *
 * Die Abwahl ist die letzte Instanz vor dem Absenden: was hier aussortiert
 * wird, erreicht den Server gar nicht erst und taucht folglich auch nicht in
 * seiner Inbox auf, wo es sonst jemand von Hand verwerfen müsste.
 *
 * @returns {Promise<{ sessions: number, skipped: number, results: object[] }>}
 */
async function uploadFile(config, file) {
    const envelope = readEnvelope(file);
    if (!envelope) return { sessions: 0, skipped: 0, results: [] };

    const excluded = new Set(Array.isArray(config.excludedSessions) ? config.excludedSessions : []);
    const sessions = Array.isArray(envelope.sessions) ? envelope.sessions : [];
    const results = [];
    let skipped = 0;
    for (const session of sessions) {
        if (!session || !Array.isArray(session.items) || !session.items.length) continue;
        if (excluded.has(session.sessionId)) { skipped += 1; continue; }
        const answer = await postSession(config, envelopeForSession(envelope, session));
        results.push(...((answer && answer.results) || []));
    }
    return { sessions: sessions.length, skipped, results };
}

/** Eine Ergebniszeile des Servers als Satz für die Konsole. */
function describeResult(r) {
    switch (r.status) {
    case "pending":
        return `neu in der Inbox — ${r.added} Item(s)${r.suggested ? `, vorgeschlagen: ${r.suggested}` : ""}`;
    case "updated":
        return `Inbox aktualisiert — ${r.added} neue(s) Item(s), jetzt ${r.total}`;
    case "appended":
        return `${r.added} Item(s) direkt zu „${r.eventLabel}" ergänzt`
                + `${r.skipped ? ` (${r.skipped} bereits vorhanden)` : ""}`;
    case "dismissed":
        return "übersprungen (im Menü verworfen)";
    case "empty":
        return "keine Items";
    default:
        return r.status;
    }
}

module.exports = { readEnvelope, uploadFile, postSession, envelopeForSession, describeResult, UploadError, SYNC_VERSION };
