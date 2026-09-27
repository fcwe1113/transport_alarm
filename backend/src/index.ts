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
	scheduled_time: string;
	require_ack: number; // 0 or 1
	expire_on: number | null;
	status: "PENDING" | "SENT";
	last_sent_at: number | null;
}

interface ScheduleRequestBody {
	device_token: string;
	scheduled_time: number; // unix timestamp in seconds
	require_ack: boolean;
}

interface AckRequestBody {
	ping_id: number;
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);

		if (request.method == "POST" && url.pathname === "/schedule") {
			try {
				const body = (await request.json()) as ScheduleRequestBody;
				if (!body.device_token || !body.scheduled_time) {
					return new Response(JSON.stringify({ error: "Missing device_token or scheduled_time" }), { status: 400 });
				}

				console.log("running insert query");

				const info = await env.DB.prepare(
					"INSERT INTO scheduled_pings (device_token, scheduled_time, require_ack, expire_on) VALUES (?, ?, ?, ?)"
				).bind(body.device_token, body.scheduled_time, body.require_ack ? 1 : 0, body.expire_on ?? null).run();

				console.log("Insert result meta:", JSON.stringify(info.meta));

				return new Response(JSON.stringify({ success: true, ping_id: info.meta.last_row_id }), { headers: { "Content-Type": "application/json" } });
			} catch (err) {
				const message = err instanceof Error ? err.message : "Unknown Error";
				return new Response(JSON.stringify({ error: message }), { status: 400 });
			}
		}

		if (request.method == "POST" && url.pathname === "/reschedule") {
    			try {
    				const body = (await request.json()) as ScheduleRequestBody;
    				if (!body.device_token || !body.scheduled_time) {
    					return new Response(JSON.stringify({ error: "Missing device_token or scheduled_time" }), { status: 400 });
    				}

    				const info = await env.DB.prepare(
    					"UPDATE scheduled_pings SET scheduled_time = ?, require_ack = ?, expire_on = ?, status = 'PENDING', last_sent_at = NULL WHERE id = ?"
    				).bind(body.scheduled_time, body.require_ack ? 1 : 0, body.expire_on ?? null, body.ping_id).run();

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
		const oneMinuteAgo = now - 60;

		const { results } = await env.DB.prepare(
			"SELECT * FROM scheduled_pings WHERE (status = 'PENDING' AND scheduled_time <= ?) OR (status = 'SENT' AND require_ack = 1 AND last_sent_at <= ? AND (expire_on IS NULL OR expire_on > ?))"
		).bind(now, oneMinuteAgo, now).all<ScheduledPing>();

		console.log(`[Cron run at ${new Date().toISOString()}] found ${results.length} jobs to process`);

		let fcmAccessToken: string | null = null;

		for (const job of results) {
			let success = false;

			if (env.APNS_PRIVATE_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC) {
				success = await sendVisiblePush(env, job);
			} else if (env.FCM_PROJECT_ID && env.FCM_CLIENT_EMAIL && env.FCM_PRIVATE_KEY) {
				fcmAccessToken ??= await getFCMAccessToken(env);
				success = fcmAccessToken ? await sendFCMPush(env, job, fcmAccessToken) : false;
			} else {
				success = await mockSendVisiblePush(job);
			}

			if (success) {
				if (job.require_ack === 1) {
					await env.DB.prepare("UPDATE scheduled_pings SET status = 'SENT', last_sent_at = ? WHERE id = ?").bind(now, job.id).run();
				} else {
					await env.DB.prepare("DELETE FROM scheduled_pings WHERE status = 'SENT' AND require_ack = 1 AND expire_on IS NOT NULL AND expire_on <= ?").bind(now).run();
				}
			}
		}
	}
};

async function sendVisiblePush(env: Env, job: ScheduledPing): Promise<boolean> {
	try {
		const token = await jwt.sign({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) }, env.APNS_PRIVATE_KEY!, { algorithm: "ES256", header: { kid: env.APNS_KEY_ID! } });
		const payload = {
			aps: {
				alert: { title: "server cronjob ping", body: "you should not be able to see this lol" },
				sound: "default",
				"mutable-content": 1
			},
			ping_id: job.id
		};

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

		return response.ok;
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
			env.FCM_PRIVATE_KEY!,
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
