import jwt from "@tsndr/cloudflare-worker-jwt"

export interface Env {
	DB: D1Database;
	APNS_KEY_ID?: string;
	APNS_TEAM_ID?: string;
	APNS_TOPIC?: string;
	APNS_PRIVATE_KEY?: string;
	FCM_PROJECT_ID?: string;
	FCM_CLIENT_EMAIL?: string;
	FCM_PRIVATE_KEY?: string;
}

interface ScheduledPing {
	id: number;
	device_token: string;
	scheduled_time: number;
	require_ack: number; // 0 or 1
	expire_on: number | null;
	status: "PENDING" | "SENT";
	last_sent_at: number | null;
}

interface ScheduleRequestBody {
	device_token: string;
	scheduled_time: number; // unix timestamp in seconds
	require_ack: boolean;
	expire_on?: number | null;
}

interface ScheduleUpdateBody {
	ping_id: string;
	scheduled_time: string;
	require_ack: number;
	expire_on: number | null;
}

interface AckRequestBody {
	ping_id: number | string;
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const retry_period = 180; // retry_period is 3 minutes
		const url = new URL(request.url);

		if (request.method == "POST" && url.pathname === "/schedule") {
			try {
				const body = (await request.json()) as ScheduleRequestBody;
				if (!body.device_token || !body.scheduled_time) {
					return new Response(JSON.stringify({ error: "Missing device_token or scheduled_time" }), { status: 400 });
				}

				const info = await env.DB.prepare(
					"INSERT INTO scheduled_pings (device_token, scheduled_time, require_ack, expire_on) VALUES (?, ?, ?, ?)"
				).bind(body.device_token, body.scheduled_time, body.require_ack ? 1 : 0, body.expire_on ?? body.scheduled_time + retry_period).run();

				return new Response(JSON.stringify({ success: true, ping_id: info.meta.last_row_id }), { headers: { "Content-Type": "application/json" } });
			} catch (err) {
				const message = err instanceof Error ? err.message : "Unknown Error";
				return new Response(JSON.stringify({ error: message }), { status: 400 });
			}
		}

		if (request.method == "POST" && url.pathname === "/reschedule") {
    			try {
    				const body = (await request.json()) as ScheduleUpdateBody;
    				if (!body.ping_id || !body.scheduled_time) {
    					return new Response(JSON.stringify({ error: "Missing ping_id or scheduled_time" }), { status: 400 });
    				}

    				const info = await env.DB.prepare(
    					"UPDATE scheduled_pings SET scheduled_time = ?, require_ack = ?, expire_on = ?, status = 'PENDING', last_sent_at = NULL WHERE id = ?"
    				).bind(body.scheduled_time, body.require_ack ? 1 : 0, body.expire_on ?? body.scheduled_time + retry_period, body.ping_id).run();

					if (info.meta.changes === 0) {
						return new Response(JSON.stringify({ error: "ping_id not found" }), { status: 404 });
					}

    				return new Response(JSON.stringify({ success: true, ping_id: info.meta.last_row_id }), { headers: { "Content-Type": "application/json" } });
    			} catch (err) {
    				const message = err instanceof Error ? err.message : "Unknown Error";
    				return new Response(JSON.stringify({ error: message }), { status: 400 });
    			}
    		}

		if (request.method == "POST" && url.pathname === "/ack") {
			try {
				const body = (await request.json()) as AckRequestBody;
				if (!body.ping_id) {
					return new Response(JSON.stringify({ error: "Missing ping_id" }), { status: 400 });
				}
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

		// A client reschedule returns the row to PENDING. SENT rows are not
		// delivered again; only a new due schedule from the client can trigger
		// another visible push.
		const { results } = await env.DB.prepare(
			"SELECT * FROM scheduled_pings WHERE status = 'PENDING' AND scheduled_time <= ? AND (expire_on IS NULL OR expire_on > ?)"
		).bind(now, now).all<ScheduledPing>();

		console.log(`[Cron run at ${new Date().toISOString()}] found ${results.length} jobs to process`);

		let fcmAccessToken: string | null = null;

		for (const job of results) {
			// Claim the row before calling APNs/FCM so overlapping cron runs do
			// not send the same due ping concurrently. A failed provider request
			// returns it to PENDING for the next cron run to retry.
			const claim = await env.DB.prepare(
				"UPDATE scheduled_pings SET status = 'SENT', last_sent_at = ? WHERE id = ? AND status = 'PENDING' AND scheduled_time <= ? AND (expire_on IS NULL OR expire_on > ?)"
			).bind(now, job.id, now, now).run();
			if (claim.meta.changes === 0) continue;

			let success = false;

			if (env.APNS_PRIVATE_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC) {
				success = await sendVisiblePush(env, job);
			} else if (env.FCM_PROJECT_ID && env.FCM_CLIENT_EMAIL && env.FCM_PRIVATE_KEY) {
				fcmAccessToken ??= await getFCMAccessToken(env);
				success = fcmAccessToken ? await sendFCMPush(env, job, fcmAccessToken) : false;
			} else {
				success = await mockSendVisiblePush(job);
			}

			if (!success) {
				await env.DB.prepare(
					"UPDATE scheduled_pings SET status = 'PENDING', last_sent_at = NULL WHERE id = ? AND status = 'SENT' AND last_sent_at = ?"
				).bind(job.id, now).run();
			}
		}
	}
};

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

async function sendVisiblePush(env: Env, job: ScheduledPing): Promise<boolean> {
	try {
		const apnsKey = await getApnsCryptoKey(env.APNS_PRIVATE_KEY!);
		const token = await getApnsJwtToken(env, apnsKey);
// 		console.log(`key: ${apnsKey}`);
// 		console.log(`token: ${token}`);

		const payload = {
			aps: {
				alert: { title: "server cronjob ping", body: "you should not be able to see this lol" },
				category: "ping",
				sound: "default",
				"mutable-content": 1,
// 				"content-available": 1,
			},
			ping_id: job.id,
		};

	console.log(`sending ping with id: ${job.id}`);

		const apnHost = "https://api.push.apple.com";
		const response = await fetch(`${apnHost}/3/device/${job.device_token}`, {
			method: "POST",
			headers: {
				authorization: `bearer ${token}`,
				"apns-topic": env.APNS_TOPIC!,
				"apns-push-type": "alert",
				"apns-priority": "10",
				"content-type": "application/json"
			},
			body: JSON.stringify(payload)
		});

		if (!response.ok) {
			const errorText = await response.text();
			console.log(`APNs push failed with HTTP ${response.status} for ping ${job.id}:`, errorText);
			return false;
		}

		console.log("sent ping");

		return true;
	} catch (error) {
		console.log(`APNs push failed for ping ${job.id}:`, error);
		return false;
	}
}

// Exchanges the FCM service account's credentials for a short-lived OAuth2
// access token, required by FCM's HTTP v1 API. Signed with RS256, unlike
// APNs' ES256 — the service account key is an RSA key, not EC.
async function getFCMAccessToken(env: Env): Promise<string | null> {
	try {
		const nowSeconds = Math.floor(Date.now() / 1000);
		const assertion = await jwt.sign(
			{
				iss: env.FCM_CLIENT_EMAIL,
				scope: "https://www.googleapis.com/auth/firebase.messaging",
				aud: "https://oauth2.googleapis.com/token",
				iat: nowSeconds,
				exp: nowSeconds + 3600
			},
			cleanKeyString(env.FCM_PRIVATE_KEY!),
			{ algorithm: "RS256" }
		);

		const response = await fetch("https://oauth2.googleapis.com/token", {
			method: "POST",
			headers: { "content-type": "application/x-www-form-urlencoded" },
			body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${assertion}`
		});

		if (!response.ok) {
			console.log("FCM token exchange failed:", await response.text());
			return null;
		}

		const data = (await response.json()) as { access_token: string };
		return data.access_token;
	} catch (error) {
		console.log("FCM token exchange error:", error);
		return null;
	}
}

async function sendFCMPush(env: Env, job: ScheduledPing, accessToken: string): Promise<boolean> {
	try {
		const payload = {
			message: {
				token: job.device_token,
				notification: {
					title: "server cronjob ping",
					body: "you should not be able to see this lol"
				},
				android: {
					notification: {
						channel_id: "alarm_test_channel"
					}
				},
				data: { ping_id: String(job.id) }
			}
		};

		const response = await fetch(`https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`, {
			method: "POST",
			headers: {
				authorization: `Bearer ${accessToken}`,
				"content-type": "application/json"
			},
			body: JSON.stringify(payload)
		});

		if (!response.ok) {
			console.log(`FCM push failed for ping ${job.id}:`, await response.text());
		}
		return response.ok;
	} catch (error) {
		console.log(`FCM push error for ping ${job.id}:`, error);
		return false;
	}
}

async function mockSendVisiblePush(job: ScheduledPing): Promise<boolean> {
	console.log(`[MOCK APNs PUSH] Triggered for Ping ID: ${job.id} -> Token: ${job.device_token}`);
	return true;
}

async function mockSendFCMPush(job: ScheduledPing): Promise<boolean> {
	console.log(`[MOCK FCM PUSH] Triggered for Ping ID: ${job.id} -> Token: ${job.device_token}`);
	return true;
}
