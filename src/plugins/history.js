// The history the server keeps for the charts (atrio-alerts, every 5 minutes): read, cut to a range,
// averaged into buckets for the week, with gaps where the server was off.
import api from '@/service/api.js'

const STATE = '/var/lib/casaos/atrio'
// Columns of history.tsv: time cpu‰ memory‰ load download upload cpu°C disk°C
const COLUMNS = ['time', 'cpu', 'memory', 'load', 'down', 'up', 'cpuTemp', 'diskTemp']

async function read(path) {
	try {
		const res = await api.file.getContent(path)
		return res.data.success === 200 ? String(res.data.data ?? '') : null
	}
	catch (e) {
		return null
	}
}

function number(text) {
	if (text === undefined || text === '') return null
	const value = Number(text)
	return Number.isFinite(value) ? value : null
}

/** The samples of the last `hours`, null when the server keeps no history (an older service). */
export async function loadHistory(hours) {
	const text = await read(`${STATE}/history.tsv`)
	if (text === null) return null
	const since = Date.now() / 1000 - hours * 3600
	const rows = text.split('\n').filter(Boolean).map((line) => {
		const cells = line.split('\t')
		const row = Object.fromEntries(COLUMNS.map((key, index) => [key, number(cells[index])]))
		if (row.cpu !== null) row.cpu /= 10
		if (row.memory !== null) row.memory /= 10
		return row
	}).filter((row) => row.time && row.time >= since)
	// A week in 30-minute averages, a day as it is
	return withGaps(hours > 24 ? buckets(rows, 1800) : rows, hours > 24 ? 1800 : 300)
}

function buckets(rows, size) {
	const groups = new Map()
	for (const row of rows) {
		const key = Math.floor(row.time / size) * size
		if (!groups.has(key)) groups.set(key, [])
		groups.get(key).push(row)
	}
	return [...groups.entries()].map(([time, group]) => {
		const out = { time: time + size / 2 }
		for (const key of COLUMNS.slice(1)) {
			const values = group.map((row) => row[key]).filter((value) => value !== null)
			out[key] = values.length ? values.reduce((a, b) => a + b, 0) / values.length : null
		}
		return out
	})
}

// A point with no values where samples are missing for long, so lines do not bridge the gap
function withGaps(rows, step) {
	const out = []
	rows.forEach((row, index) => {
		if (index && row.time - rows[index - 1].time > step * 3) {
			out.push({ time: rows[index - 1].time + step, ...Object.fromEntries(COLUMNS.slice(1).map((key) => [key, null])) })
		}
		out.push(row)
	})
	return out
}

/** Each app's CPU (% of one core) and memory (MiB) in the last sample: [{ app, cpu, memory }] */
export async function loadAppUsage() {
	const text = await read(`${STATE}/history-apps.tsv`)
	if (!text) return []
	const rows = text.split('\n').filter(Boolean).map((line) => line.split('\t'))
	const last = Math.max(...rows.map((row) => Number(row[0]) || 0))
	return rows.filter((row) => Number(row[0]) === last && !row[1].startsWith('svc:'))
		.map(([, app, cpu, memory]) => ({ app, cpu: Number(cpu) || 0, memory: Number(memory) || 0 }))
		.sort((a, b) => b.memory - a.memory)
}

/**
 * Bytes received and sent over the last 24 hours, from the 5-minute samples: the apps, the server's
 * services (svc:<unit>) and the whole server. { apps: [{ app, down, up }], services: [{ name, down, up }], server: { down, up } }
 */
export async function loadDayTraffic() {
	const [apps, history] = await Promise.all([read(`${STATE}/history-apps.tsv`), read(`${STATE}/history.tsv`)])
	const totals = new Map()
	const last = new Map()
	for (const line of (apps || '').split('\n').filter(Boolean)) {
		const [time, name, , , down, up] = line.split('\t')
		const seconds = last.has(name) ? Math.min(Number(time) - last.get(name), 900) : 300
		last.set(name, Number(time))
		const total = totals.get(name) || { down: 0, up: 0 }
		total.down += (Number(down) || 0) * seconds
		total.up += (Number(up) || 0) * seconds
		totals.set(name, total)
	}
	const server = { down: 0, up: 0 }
	const since = Date.now() / 1000 - 86400
	let previous = null
	for (const line of (history || '').split('\n').filter(Boolean)) {
		const cells = line.split('\t')
		const time = Number(cells[0])
		if (time < since) continue
		const seconds = previous ? Math.min(time - previous, 900) : 300
		previous = time
		server.down += (Number(cells[4]) || 0) * seconds
		server.up += (Number(cells[5]) || 0) * seconds
	}
	const list = [...totals.entries()]
	return {
		apps: list.filter(([name]) => !name.startsWith('svc:')).map(([app, t]) => ({ app, ...t })),
		services: list.filter(([name]) => name.startsWith('svc:')).map(([name, t]) => ({ name: name.slice(4), ...t })),
		server,
	}
}
