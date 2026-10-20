import jwt from "@tsndr/cloudflare-worker-jwt"

export interface Env {
	DB: D1Database;
	APNS_KEY_ID?: string;
	APNS_TEAM_ID?: string;
	APNS_TOPIC?: string;
	APNS_PRIVATE_KEY?: string;
}

interface ScheduledPing {
	id: string; // random UUID, so IDs can't be guessed
	secret_hash: string; // SHA-256 of the secret returned to the client
	device_token: string;
	scheduled_time: number;
	require_ack: number; // 0 or 1
	expire_on: number | null;
	status: "PENDING" | "SENT";
	last_sent_at: number | null;
	fallback_count: number; // resends since the client last rescheduled
}

interface ScheduleRequestBody {
	device_token: string;
	// Seconds from now by the Worker's clock, so the phone's clock doesn't
	// matter. scheduled_time is still accepted from older builds.
	delay_seconds?: number;
	scheduled_time?: number; // unix timestamp in seconds
	require_ack: boolean;
	expire_on?: number | null;
}

interface ScheduleUpdateBody {
	ping_id: string;
	ping_secret: string;
	delay_seconds?: number;
	scheduled_time?: number;
	require_ack: number;
	expire_on: number | null;
}

interface UpdateTokenBody {
	ping_id: string;
	ping_secret: string;
	device_token: string;
}

interface AckRequestBody {
	ping_id: string;
	ping_secret: string;
}

// A device can't hold more pending pings than this, so one client can't fill
// the table or make the cron push to it without limit.
const MAX_PINGS_PER_DEVICE = 25;
// Furthest ahead a ping can be scheduled (a monthly repeat, plus margin).
const MAX_SCHEDULE_AHEAD_SECONDS = 400 * 24 * 3600;
// How long a row lives past its scheduled time when the client sets no
// expiry: long enough for its fallback resends.
const DEFAULT_EXPIRY_SECONDS = 20 * 60;
// A sent ping the client hasn't rescheduled by this long after is sent
// again, in case the push or the extension run was lost.
const FALLBACK_AFTER_SECONDS = 5 * 60;
const MAX_FALLBACKS = 3;
const DEVICE_TOKEN_PATTERN = /^[0-9a-fA-F]{64,200}$/;

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function sha256Hex(text: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomSecret(): string {
	const bytes = crypto.getRandomValues(new Uint8Array(32));
	return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The ping's Unix time from delay_seconds, or the older scheduled_time;
 * null if neither is valid. */
function resolveScheduledTime(body: { delay_seconds?: unknown; scheduled_time?: unknown }, now: number): number | null {
	let time: number;
	if (typeof body.delay_seconds === "number" && Number.isFinite(body.delay_seconds)) {
		time = now + Math.max(0, Math.floor(body.delay_seconds));
	} else if (typeof body.scheduled_time === "number" && Number.isFinite(body.scheduled_time)) {
		time = Math.floor(body.scheduled_time);
	} else {
		return null;
	}
	return time > now + MAX_SCHEDULE_AHEAD_SECONDS ? null : time;
}

/** Checks the client owns [pingId]: a Response to return if not, or null. */
async function rejectUnlessOwner(env: Env, pingId: unknown, secret: unknown): Promise<Response | null> {
	if (typeof pingId !== "string" || typeof secret !== "string" || !pingId || !secret) {
		return json({ error: "Missing ping_id or ping_secret" }, 400);
	}
	const row = await env.DB.prepare("SELECT secret_hash FROM scheduled_pings WHERE id = ?")
		.bind(pingId).first<{ secret_hash: string }>();
	if (!row) return json({ error: "ping_id not found" }, 404);
	if (row.secret_hash !== (await sha256Hex(secret))) return json({ error: "Forbidden" }, 403);
	return null;
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);

		if (request.method == "POST" && url.pathname === "/schedule") {
			try {
				const body = (await request.json()) as ScheduleRequestBody;
				const now = Math.floor(Date.now() / 1000);
				const scheduledTime = resolveScheduledTime(body, now);
				if (typeof body.device_token !== "string" || !DEVICE_TOKEN_PATTERN.test(body.device_token) || scheduledTime === null) {
					return json({ error: "Invalid device_token, delay_seconds or scheduled_time" }, 400);
				}
				const pending = await env.DB.prepare("SELECT COUNT(*) AS count FROM scheduled_pings WHERE device_token = ?")
					.bind(body.device_token).first<{ count: number }>();
				if ((pending?.count ?? 0) >= MAX_PINGS_PER_DEVICE) {
					return json({ error: "Too many scheduled pings for this device" }, 429);
				}

				// The secret is returned once and only its hash is stored; reschedule
				// and ack calls must present it.
				const pingId = crypto.randomUUID();
				const secret = randomSecret();
				await env.DB.prepare(
					"INSERT INTO scheduled_pings (id, secret_hash, device_token, scheduled_time, require_ack, expire_on) VALUES (?, ?, ?, ?, ?, ?)"
				).bind(pingId, await sha256Hex(secret), body.device_token, scheduledTime, body.require_ack ? 1 : 0, body.expire_on ?? scheduledTime + DEFAULT_EXPIRY_SECONDS).run();

				return json({ success: true, ping_id: pingId, ping_secret: secret });
			} catch (err) {
				const message = err instanceof Error ? err.message : "Unknown Error";
				return new Response(JSON.stringify({ error: message }), { status: 400 });
			}
		}

		if (request.method == "POST" && url.pathname === "/reschedule") {
    			try {
    				const body = (await request.json()) as ScheduleUpdateBody;
    				const scheduledTime = resolveScheduledTime(body, Math.floor(Date.now() / 1000));
    				if (!body.ping_id || scheduledTime === null) {
    					return json({ error: "Missing ping_id, or invalid delay_seconds or scheduled_time" }, 400);
    				}
    				const rejected = await rejectUnlessOwner(env, body.ping_id, body.ping_secret);
    				if (rejected) return rejected;

    				const info = await env.DB.prepare(
    					"UPDATE scheduled_pings SET scheduled_time = ?, require_ack = ?, expire_on = ?, status = 'PENDING', last_sent_at = NULL, fallback_count = 0 WHERE id = ?"
    				).bind(scheduledTime, body.require_ack ? 1 : 0, body.expire_on ?? scheduledTime + DEFAULT_EXPIRY_SECONDS, body.ping_id).run();

					if (info.meta.changes === 0) {
						return new Response(JSON.stringify({ error: "ping_id not found" }), { status: 404 });
					}

    				return json({ success: true, ping_id: body.ping_id });
    			} catch (err) {
    				const message = err instanceof Error ? err.message : "Unknown Error";
    				return new Response(JSON.stringify({ error: message }), { status: 400 });
    			}
    		}

		// Moves a ping to the device's current push token, after iOS issues a
		// new one. A 404 tells the app the ping is gone and to schedule anew.
		if (request.method == "POST" && url.pathname === "/update_token") {
			try {
				const body = (await request.json()) as UpdateTokenBody;
				if (typeof body.device_token !== "string" || !DEVICE_TOKEN_PATTERN.test(body.device_token)) {
					return json({ error: "Invalid device_token" }, 400);
				}
				const rejected = await rejectUnlessOwner(env, body.ping_id, body.ping_secret);
				if (rejected) return rejected;
				await env.DB.prepare("UPDATE scheduled_pings SET device_token = ? WHERE id = ?")
					.bind(body.device_token, body.ping_id).run();
				return json({ success: true, ping_id: body.ping_id });
			} catch (err) {
				const message = err instanceof Error ? err.message : "Unknown Error";
				return json({ error: message }, 400);
			}
		}

		if (request.method == "POST" && url.pathname === "/ack") {
			try {
				const body = (await request.json()) as AckRequestBody;
				const rejected = await rejectUnlessOwner(env, body.ping_id, body.ping_secret);
				if (rejected) return rejected;
				await env.DB.prepare("DELETE FROM scheduled_pings WHERE id = ?").bind(body.ping_id).run();
				return new Response(JSON.stringify({ acknowledged: true }), { headers: { "Content-Type": "application/json" } });
			} catch (err) {
				const message = err instanceof Error ? err.message : "Unknown Error";
				return new Response(JSON.stringify({ error: message }), { status: 400 });
			}
		}
		return new Response("Not Found", { status: 404 });
	},

	async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
		const now = Math.floor(Date.now() / 1000);

		// Expired rows no longer represent an active client schedule.
		await env.DB.prepare("DELETE FROM scheduled_pings WHERE expire_on IS NOT NULL AND expire_on <= ?").bind(now).run();

		// A client reschedule returns the row to PENDING. A SENT row the client
		// hasn't rescheduled is sent again after FALLBACK_AFTER_SECONDS, up to
		// MAX_FALLBACKS times, so a lost push or extension run doesn't end the
		// alarm's chain of pings.
		const { results } = await env.DB.prepare(
			"SELECT * FROM scheduled_pings WHERE ((status = 'PENDING' AND scheduled_time <= ?) OR (status = 'SENT' AND last_sent_at <= ? AND fallback_count < ?)) AND (expire_on IS NULL OR expire_on > ?)"
		).bind(now, now - FALLBACK_AFTER_SECONDS, MAX_FALLBACKS, now).all<ScheduledPing>();

		console.log(`[Cron run at ${new Date().toISOString()}] found ${results.length} jobs to process`);

		const deadTokens = new Set<string>();
		for (const job of results) {
			if (deadTokens.has(job.device_token)) continue;
			const isFallback = job.status === "SENT";
			// Claim the row before calling APNs so overlapping cron runs do
			// not send the same due ping concurrently. A failed provider request
			// puts the row back for the next cron run to retry.
			const claim = isFallback
				? await env.DB.prepare(
					"UPDATE scheduled_pings SET last_sent_at = ?, fallback_count = fallback_count + 1 WHERE id = ? AND status = 'SENT' AND last_sent_at = ? AND fallback_count = ?"
				).bind(now, job.id, job.last_sent_at, job.fallback_count).run()
				: await env.DB.prepare(
					"UPDATE scheduled_pings SET status = 'SENT', last_sent_at = ? WHERE id = ? AND status = 'PENDING' AND scheduled_time <= ? AND (expire_on IS NULL OR expire_on > ?)"
				).bind(now, job.id, now, now).run();
			if (claim.meta.changes === 0) continue;

			const result: PushResult = env.APNS_PRIVATE_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC
				? await sendVisiblePush(env, job)
				: await mockSendVisiblePush(job);

			if (result === "deadToken") {
				// APNs will never deliver to this token again; the app moves its
				// alarms to the new token, or schedules new pings, on its next launch.
				deadTokens.add(job.device_token);
				await env.DB.prepare("DELETE FROM scheduled_pings WHERE device_token = ?").bind(job.device_token).run();
			} else if (result === "retry") {
				if (isFallback) {
					await env.DB.prepare(
						"UPDATE scheduled_pings SET last_sent_at = ?, fallback_count = ? WHERE id = ? AND status = 'SENT' AND last_sent_at = ?"
					).bind(job.last_sent_at, job.fallback_count, job.id, now).run();
				} else {
					await env.DB.prepare(
						"UPDATE scheduled_pings SET status = 'PENDING', last_sent_at = NULL WHERE id = ? AND status = 'SENT' AND last_sent_at = ?"
					).bind(job.id, now).run();
				}
			}
		}
	}
};

/** sent: delivered to APNs. retry: try again next cron run. deadToken: APNs
 * rejected the device token for good. */
type PushResult = "sent" | "retry" | "deadToken";

function cleanKeyString(rawKey: string): string {
	let key = rawKey.trim();
	// Strip surrounding double or single quotes
	if ((key.startsWith('"') && key.endsWith('"')) || (key.startsWith("'") && key.endsWith("'"))) {
		key = key.slice(1, -1).trim();
	}
	// Replace literal escaped \n and \r with actual newlines
	key = key.replace(/\\n/g, "\n").replace(/\\r/g, "\r").trim();
	if (key.includes("\\n")) {
		key = key.replace(/\\n/g, "\n").replace(/\\r/g, "\r").trim();
	}
	return key;
}

function base64ToUint8Array(base64: string): Uint8Array {
	const binaryString = atob(base64);
	const bytes = new Uint8Array(binaryString.length);
	for (let i = 0; i < binaryString.length; i++) {
		bytes[i] = binaryString.charCodeAt(i);
	}
	return bytes;
}

function sec1ToPkcs8(sec1Bytes: Uint8Array): Uint8Array {
	// PKCS#8 wrapper for EC prime256v1 (P-256)
	// AlgorithmIdentifier for id-ecPublicKey (1.2.840.10045.2.1) + prime256v1 (1.2.840.10045.3.1.7)
	const algorithmIdentifier = new Uint8Array([
		0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07
	]);

	const sec1Len = sec1Bytes.length;
	const octetStringHeader: number[] = sec1Len < 128
		? [0x04, sec1Len]
		: sec1Len < 256
		? [0x04, 0x81, sec1Len]
		: [0x04, 0x82, (sec1Len >> 8) & 0xff, sec1Len & 0xff];

	const bodyLength = 3 + algorithmIdentifier.length + octetStringHeader.length + sec1Len;
	const sequenceHeader: number[] = bodyLength < 128
		? [0x30, bodyLength]
		: bodyLength < 256
		? [0x30, 0x81, bodyLength]
		: [0x30, 0x82, (bodyLength >> 8) & 0xff, bodyLength & 0xff];

	const pkcs8 = new Uint8Array(sequenceHeader.length + bodyLength);
	let offset = 0;
	pkcs8.set(sequenceHeader, offset); offset += sequenceHeader.length;
	pkcs8.set([0x02, 0x01, 0x00], offset); offset += 3;
	pkcs8.set(algorithmIdentifier, offset); offset += algorithmIdentifier.length;
	pkcs8.set(octetStringHeader, offset); offset += octetStringHeader.length;
	pkcs8.set(sec1Bytes, offset);

	return pkcs8;
}

let cachedApnsKey: { raw: string; key: CryptoKey } | null = null;

async function getApnsCryptoKey(rawKey: string): Promise<CryptoKey> {
	if (cachedApnsKey && cachedApnsKey.raw === rawKey) {
		return cachedApnsKey.key;
	}

	const cleaned = cleanKeyString(rawKey);
	const isSec1 = cleaned.includes("BEGIN EC PRIVATE KEY");

	// Strip PEM headers/footers and any whitespace
	const cleanBase64 = cleaned
		.replace(/-----BEGIN [A-Z ]+-----/g, "")
		.replace(/-----END [A-Z ]+-----/g, "")
		.replace(/\s+/g, "");

	if (!cleanBase64) {
		throw new Error("APNS_PRIVATE_KEY is empty after stripping PEM headers.");
	}

	let der: Uint8Array;
	try {
		der = base64ToUint8Array(cleanBase64);
	} catch (err) {
		throw new Error(`Failed to base64-decode APNS_PRIVATE_KEY: ${err instanceof Error ? err.message : String(err)}`);
	}

	if (isSec1) {
		der = sec1ToPkcs8(der);
	}

	let importedKey: CryptoKey;
	try {
		importedKey = await crypto.subtle.importKey(
			"pkcs8",
			der,
			{ name: "ECDSA", namedCurve: "P-256" },
			false,
			["sign"]
		);
	} catch (primaryErr) {
		// If direct PKCS#8 import failed and wasn't explicitly marked SEC1, try converting as SEC1
		if (!isSec1) {
			try {
				const converted = sec1ToPkcs8(der);
				importedKey = await crypto.subtle.importKey(
					"pkcs8",
					converted,
					{ name: "ECDSA", namedCurve: "P-256" },
					false,
					["sign"]
				);
			} catch (_) {
				throw new Error(
					`Invalid PKCS8/EC input for APNS_PRIVATE_KEY (${primaryErr instanceof Error ? primaryErr.message : String(primaryErr)}). ` +
					`Key base64 length: ${cleanBase64.length} chars. Ensure this is an EC P-256 key from Apple (.p8).`
				);
			}
		} else {
			throw primaryErr;
		}
	}

	cachedApnsKey = { raw: rawKey, key: importedKey };
	return importedKey;
}

let cachedApnsJwt: { token: string; exp: number; teamId: string; keyId: string } | null = null;

async function getApnsJwtToken(env: Env, apnsKey: CryptoKey): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	if (
		cachedApnsJwt &&
		cachedApnsJwt.exp > now + 300 &&
		cachedApnsJwt.teamId === env.APNS_TEAM_ID &&
		cachedApnsJwt.keyId === env.APNS_KEY_ID
	) {
		return cachedApnsJwt.token;
	}

	// Apple allows tokens to be valid for up to 1 hour (3600s). We'll set 50 minutes (3000s).
	const token = await jwt.sign(
		{ iss: env.APNS_TEAM_ID, iat: now },
		apnsKey,
		{ algorithm: "ES256", header: { kid: env.APNS_KEY_ID! } }
	);

	cachedApnsJwt = {
		token,
		exp: now + 3000,
		teamId: env.APNS_TEAM_ID!,
		keyId: env.APNS_KEY_ID!
	};

	return token;
}

async function sendVisiblePush(env: Env, job: ScheduledPing): Promise<PushResult> {
	try {
		const apnsKey = await getApnsCryptoKey(env.APNS_PRIVATE_KEY!);
		const token = await getApnsJwtToken(env, apnsKey);
// 		console.log(`key: ${apnsKey}`);
// 		console.log(`token: ${token}`);

		const payload = {
			aps: {
				// Only shown if the notification service extension fails to
				// replace it.
				alert: { title: "Transport Alarm", body: "Checking your alarm…" },
				category: "ping",
				// No sound here: the notification service extension picks one
				// per notice, keeping update pings silent.
				"mutable-content": 1,
// 				"content-available": 1,
			},
			ping_id: job.id,
		};

// 	console.log(`sending ping with id: ${job.id}`);

		const apnHost = "https://api.push.apple.com";
		const response = await fetch(`${apnHost}/3/device/${job.device_token}`, {
			method: "POST",
			headers: {
				authorization: `bearer ${token}`,
				"apns-topic": env.APNS_TOPIC!,
				"apns-push-type": "alert",
				"apns-priority": "10",
				// Each ping replaces the alarm's previous notification rather than
				// stacking up in Notification Center.
				"apns-collapse-id": String(job.id),
				"content-type": "application/json"
			},
			body: JSON.stringify(payload)
		});

		if (!response.ok) {
			const errorText = await response.text();
			console.log(`APNs push failed with HTTP ${response.status} for ping ${job.id}:`, errorText);
			let reason: unknown;
			try {
				reason = (JSON.parse(errorText) as { reason?: unknown }).reason;
			} catch (_) {
				reason = undefined;
			}
			if (response.status === 410 || (response.status === 400 && reason === "BadDeviceToken")) {
				return "deadToken";
			}
			return "retry";
		}

// 		console.log("sent ping");

		return "sent";
	} catch (error) {
		console.log(`APNs push failed for ping ${job.id}:`, error);
		return "retry";
	}
}

async function mockSendVisiblePush(job: ScheduledPing): Promise<PushResult> {
	console.log(`[MOCK APNs PUSH] Triggered for Ping ID: ${job.id} -> Token: ${job.device_token}`);
	return "sent";
}
