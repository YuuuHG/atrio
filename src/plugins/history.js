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
	return rows.filter((row) => Number(row[0]) === last)
		.map(([, app, cpu, memory]) => ({ app, cpu: Number(cpu) || 0, memory: Number(memory) || 0 }))
		.sort((a, b) => b.memory - a.memory)
}

/** Bytes received and sent by each app over the last 24 hours, from the 5-minute samples: [{ app, down, up }] */
export async function loadAppTraffic() {
	const text = await read(`${STATE}/history-apps.tsv`)
	if (!text) return []
	const totals = new Map()
	const last = new Map()
	for (const line of text.split('\n').filter(Boolean)) {
		const [time, app, , , down, up] = line.split('\t')
		const seconds = last.has(app) ? Math.min(Number(time) - last.get(app), 900) : 300
		last.set(app, Number(time))
		if (down === '-') {
			totals.set(app, { app, host: true })
			continue
		}
		const total = totals.get(app) || { app, down: 0, up: 0 }
		total.down += (Number(down) || 0) * seconds
		total.up += (Number(up) || 0) * seconds
		totals.set(app, total)
	}
	return [...totals.values()]
}
