// Atrio's own updates, shared by the settings row (AtrioUpdate), the dot on the settings icon
// (TopBar) and the full-page progress screen (AtrioUpdateScreen).
// The update itself runs on the server: we create the request file through the CasaOS file API and
// atrio-update (installed by scripts/install.sh) reports its progress in the status file.
import { reactive } from 'vue'
import api from '@/service/api.js'
import { reloadFresh } from '@/plugins/reloadFresh'

const REPO = 'peppeaiello/atrio'
const STATE = '/var/lib/casaos/atrio'
const POLL_MS = 2000
const TIMEOUT_MS = 5 * 60 * 1000
// The settings icon stays up to date on a page left open for days
const RECHECK_MS = 6 * 60 * 60 * 1000
const RETRY_MS = 5 * 60 * 1000

/* global __ATRIO_VERSION__ */
export const CURRENT = __ATRIO_VERSION__

export const release = reactive({
	latest: '',
	checking: false,
	checkFailed: false,
	updaterInstalled: null,
	// Set while an update runs: { step, message, error, to }
	run: null,
})

// Semantic versions: 1.2.0 > 1.2.0-rc.2 > 1.2.0-rc.1
function parseVersion(version) {
	const [core, pre = ''] = version.replace(/^v/, '').split('-', 2)
	return { core: core.split('.').map((n) => Number(n) || 0), pre: pre ? pre.split('.') : [] }
}

export function isNewer(latest, current) {
	const a = parseVersion(latest)
	const b = parseVersion(current)
	for (let i = 0; i < 3; i++) {
		if ((a.core[i] || 0) !== (b.core[i] || 0)) return (a.core[i] || 0) > (b.core[i] || 0)
	}
	if (!a.pre.length || !b.pre.length) return !a.pre.length && b.pre.length > 0
	for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
		const x = a.pre[i]
		const y = b.pre[i]
		if (x === undefined || y === undefined) return y === undefined
		if (x === y) continue
		const nx = Number(x)
		const ny = Number(y)
		if (!Number.isNaN(nx) && !Number.isNaN(ny)) return nx > ny
		return x > y
	}
	return false
}

export function updateAvailable() {
	// In development checkLatest never runs, so latest stays empty
	return !!release.latest && isNewer(release.latest, CURRENT)
}

async function readStatus() {
	try {
		const res = await api.file.getContent(`${STATE}/update-status.json`)
		return res.data.success === 200 ? JSON.parse(res.data.data) : null
	}
	catch (e) {
		return null
	}
}

let lastCheck = 0
let checking = null
let retryTimer

/** Asks GitHub for the latest release; repeated calls within RECHECK_MS reuse the last answer. */
export function checkLatest({ force = false } = {}) {
	if (import.meta.env.DEV) return Promise.resolve()
	if (checking) return checking
	if (!force && lastCheck && Date.now() - lastCheck < RECHECK_MS) return Promise.resolve()
	release.checking = true
	release.checkFailed = false
	checking = (async () => {
		try {
			const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } })
			if (res.status === 404) release.latest = ''
			else if (res.ok) release.latest = (await res.json()).tag_name
			else release.checkFailed = true
		}
		catch (e) {
			release.checkFailed = true
		}
		release.updaterInstalled = (await readStatus()) !== null
		// A failed check (GitHub down or rate limited) is tried again soon, not in 6 hours
		lastCheck = release.checkFailed ? 0 : Date.now()
		clearTimeout(retryTimer)
		if (release.checkFailed) retryTimer = setTimeout(checkLatest, RETRY_MS)
		release.checking = false
		checking = null
	})()
	return checking
}

export function startRechecking() {
	checkLatest()
	return setInterval(checkLatest, RECHECK_MS)
}

// Steps of the progress screen, recognised from the messages atrio-update writes
export const STEPS = ['Preparing', 'Downloading', 'Installing', 'Restarting CasaOS', 'Reloading']
function stepOf(message, current) {
	if (/^Downloading/.test(message)) return 1
	if (/^Installing/.test(message)) return 2
	if (/^Restarting/.test(message)) return 3
	return current
}

let pollTimer

// The updater sees the request file appear (a systemd path unit) and copies the token into its status
async function writeRequest(token) {
	const request = `${STATE}/update-request.tmp`
	// A copy left by an earlier try that failed halfway is simply written over
	await api.file.create(request).catch(() => {})
	const written = await api.file.update(request, token)
	if (written.data.success !== 200) throw new Error('request')
	// Renamed in place so the updater only ever sees a complete request
	const renamed = await api.file.rename(request, `${STATE}/update-request`)
	if (renamed.data.success !== 200) throw new Error('request')
}

/** Starts the update on the server and follows it until the page reloads or it fails. */
export async function startUpdate() {
	if (release.run && !release.run.error) return
	release.run = { step: 0, message: '', error: '', to: release.latest }
	const started = Date.now()
	// The updater copies this token into its status, so we know the status is about this run
	const token = `${started.toString(36)}-${Math.random().toString(36).slice(2, 10)}`
	try {
		// Services older than this web UI: the updater it ships goes in first, so that this update
		// brings the services too, even on a server whose updater only knows the web UI
		if (await checkServices()) await ensureUpdater()
		await writeRequest(token)
	}
	catch (e) {
		release.run.error = 'Could not reach the updater on the server'
		return
	}
	const poll = async () => {
		// While the gateway restarts the status cannot be read: keep waiting
		const status = await readStatus()
		// Updaters installed before 0.1.3 write no token: fall back to the time of the status
		const fresh = status && ('token' in status ? status.token === token : Date.parse(status.time) >= started - 5000)
		if (fresh && status.state === 'done') {
			release.run.step = 4
			setTimeout(reloadFresh, 1500)
			return
		}
		if (fresh && status.state === 'error') {
			release.run.error = status.message || 'The update failed, Atrio was not changed'
			return
		}
		if (Date.now() - started > TIMEOUT_MS) {
			release.run.error = 'The update is taking too long'
			return
		}
		if (fresh && status.message) {
			release.run.message = status.message
			release.run.step = stepOf(status.message, release.run.step)
		}
		pollTimer = setTimeout(poll, POLL_MS)
	}
	pollTimer = setTimeout(poll, POLL_MS)
}

// The services on the server (updater, push alerts, backups) of the version they came with: the updater
// writes it since 0.1.17, so older installs, which update the web UI only, have none. repairServer
// below brings them up to date; the install command is only shown when that cannot work.
export const INSTALL_COMMAND = 'curl -fsSL https://raw.githubusercontent.com/peppeaiello/atrio/main/scripts/install.sh | sudo bash'
export const services = reactive({ outdated: false, checked: false })
// CasaOS's answer to reading a file that does not exist (with HTTP 500)
const FILE_MISSING = 60001

/** true when the services on the server are older than this web UI. `force` reads them again. */
export async function checkServices({ force = false } = {}) {
	if (import.meta.env.DEV || (services.checked && !force)) return services.outdated
	try {
		const res = await api.file.getContent(`${STATE}/server-version`)
		const version = res.data.success === 200 ? String(res.data.data ?? '').trim() : ''
		services.outdated = !version || isNewer(CURRENT, version)
		services.checked = true
	}
	catch (e) {
		// The server answered: no such file. CasaOS says so with a 500 and its own code 60001, so that
		// one counts as missing too. Without an answer, logged out (401) or another server error,
		// asked again on the next page load
		const status = e.response?.status
		if ((status && status !== 401 && status < 500) || e.response?.data?.success === FILE_MISSING) {
			services.outdated = true
			services.checked = true
		}
	}
	return services.outdated
}

/*
 * Self-repair of the services on the server, with no command to run.
 *
 * The updater that runs on the server is the one installed with Atrio. Old ones (before 0.1.17) only
 * install the web UI, so the server's services stayed old forever, unless someone ran the install
 * command again. But the web UI does arrive, and through the CasaOS file API (which runs as root) it
 * can write the updater: each release ships its updater and public key in www/server
 * (scripts/release.sh). When the services are older than this web UI, the web UI writes that
 * updater over the installed one (in place, so it stays root's and executable) and asks for an
 * update. The new updater adopts the key if the server has none, checks the release's signature and
 * installs its services (scripts/atrio-update). It stays on for good: whatever left the services
 * behind (an old install, an update cut short, a mistake of ours in an updater), the next visit
 * puts them right. Only when that cannot work does the web UI show the install command.
 */
const UPDATER = '/usr/local/bin/atrio-update'
const SHIPPED = '/var/lib/casaos/www/server/atrio-update'
// "version time" of the last try, shared by every browser: one try every few hours, not every page load
const REPAIR_MARK = `${STATE}/repair-attempt`
const REPAIR_EVERY_MS = 6 * 60 * 60 * 1000
const REPAIR_TIMEOUT_MS = 10 * 60 * 1000
// running: a repair is under way; failed: it cannot work here, the install command is the way
// done: this visit brought them up to date
export const repair = reactive({ running: false, failed: false, done: false, message: '' })

async function readText(path) {
	try {
		const res = await api.file.getContent(path)
		return res.data.success === 200 ? String(res.data.data ?? '') : null
	}
	catch (e) {
		return null
	}
}

/**
 * Puts the updater shipped with this web UI in place of the installed one. 'ok' when it is there,
 * 'busy' when an update runs (try later), 'no' when it cannot be done on this server.
 */
export async function ensureUpdater() {
	const shipped = await readText(SHIPPED)
	// A web UI without it (a development build, or one put back by CasaOS) has nothing to give
	if (!shipped || !shipped.startsWith('#!/bin/bash\n')) return 'no'
	const installed = await readText(UPDATER)
	// No updater at all: there is no systemd unit to run one either
	if (installed === null) return 'no'
	if (installed === shipped) return 'ok'
	// Never written over while it runs: old updaters are read by bash as it goes, so a new text
	// under a running one would run pieces of it. Not while one runs, nor in the two minutes after one
	// finished: it still writes its log, and the new web UI it put in starts its restore unit, which
	// sleeps 30 seconds before it looks and leaves. A "running" left by an updater that died is
	// stale after 15 minutes.
	const status = await readStatus()
	const age = status ? Date.now() - Date.parse(status.time) : Infinity
	if (age < 2 * 60 * 1000 || (status?.state === 'running' && age < 15 * 60 * 1000)) return 'busy'
	try {
		const written = await api.file.update(UPDATER, shipped)
		if (written.data.success !== 200) return 'no'
	}
	catch (e) {
		return 'no'
	}
	// Read back: the request below must only ever start a complete updater
	if ((await readText(UPDATER)) === shipped) return 'ok'
	// Something else ended up there: the old one goes back, as it was
	await api.file.update(UPDATER, installed).catch(() => {})
	return 'no'
}

async function markRepair() {
	await api.file.create(REPAIR_MARK).catch(() => {})
	await api.file.update(REPAIR_MARK, `${CURRENT} ${Date.now()}`).catch(() => {})
}

// How long ago this version was last tried, Infinity when never
async function lastTry() {
	const [version, time] = String((await readText(REPAIR_MARK)) ?? '').trim().split(' ')
	const ago = Date.now() - Number(time)
	return version === CURRENT && ago >= 0 ? ago : Infinity
}

function waitForUpdater(token) {
	const started = Date.now()
	return new Promise((resolve) => {
		const poll = async () => {
			const status = await readStatus()
			if (status?.token === token && (status.state === 'done' || status.state === 'error')) return resolve(status)
			if (Date.now() - started > REPAIR_TIMEOUT_MS) return resolve(null)
			setTimeout(poll, POLL_MS)
		}
		setTimeout(poll, POLL_MS)
	})
}

/**
 * Brings the services on the server up to this web UI's version, when they are behind. Run on every
 * page load; most of the time it only reads one small file.
 */
let repairing = null
export function repairServer() {
	// The notification center and the settings both ask: one repair at a time
	if (!repairing) repairing = runRepair().finally(() => { repairing = null })
	return repairing
}

async function runRepair() {
	if (import.meta.env.DEV || repair.running) return
	if (!(await checkServices())) return
	// Only when this web UI is the latest release: otherwise the update offered in the settings does
	// it (startUpdate puts the new updater in first), and brings the newer web UI with it
	await checkLatest()
	if (!release.latest || isNewer(release.latest, CURRENT) || isNewer(CURRENT, release.latest)) return
	if (release.run) return
	const ago = await lastTry()
	// Under way in another browser or tab
	if (ago < REPAIR_TIMEOUT_MS) return
	if (ago < REPAIR_EVERY_MS) {
		// Tried a while ago and the services are still behind: it does not work on this server
		repair.failed = true
		return
	}
	repair.running = true
	repair.failed = false
	const ready = await ensureUpdater()
	// An update runs right now, or has just finished: tried again in a couple of minutes
	if (ready === 'busy') {
		repair.running = false
		setTimeout(repairServer, 2 * 60 * 1000)
		return
	}
	await markRepair()
	const token = `repair-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
	let status = null
	if (ready === 'ok') {
		try {
			await writeRequest(token)
			status = await waitForUpdater(token)
		}
		catch (e) {
			status = null
		}
	}
	const outdated = await checkServices({ force: true })
	repair.running = false
	repair.failed = outdated
	repair.done = !outdated
	repair.message = outdated ? (status?.message || '') : ''
}

export function dismissUpdate() {
	clearTimeout(pollTimer)
	release.run = null
}
