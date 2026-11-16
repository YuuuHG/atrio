<script>
// Details of the machine running CasaOS: system, processor, memory and every sensor it reports.
// Opened with `$EventBus.$emit('atrio:open-hardware')`; shares the sheet styles of AppDetailsPanel.
import { discoverSensors, readLive, readStatic } from '@/plugins/hardware'
import { restoreFocus, trapTab } from '@/plugins/focusTrap'
import { renderSize } from '@/mixins/file_utils'
import { ice_i18n } from '@/mixins/base/common-i18n'
import { diskId, loadAppUsage, loadDiskTemps, loadHistory } from '@/plugins/history'
import HistoryStrips from '@/components/home/HistoryStrips.vue'
import { startDiskTest } from '@/plugins/appBackup'

const POLL_MS = 3000
// The history's one hue, checked for contrast on the panel's dark surface (dataviz validator)
const COLORS = ['#0aa5c4']
// SMART data of the disks, read every hour by atrio-alerts on the server
const DISKS = '/var/lib/casaos/atrio/disks.json'
// SELFTEST=0 there turns the scheduled self-tests off
const ALERTS_CONF = '/var/lib/casaos/atrio/alerts.conf'
const VERDICTS = { good: 'Good', watch: 'Keep an eye on it', replace: 'Replace soon', unknown: 'No SMART data' }
const REASONS = {
	'failed': 'The disk says its own health check failed.',
	'test-failed': 'Its latest self-test failed.',
	'pending': 'Some sectors could not be read and wait to be replaced: this often comes before a failure.',
	'uncorrectable': 'Errors the disk could not correct.',
	'media-errors': 'Data integrity errors.',
	'critical-warning': 'The disk raised a critical warning.',
	'worn-out': 'Its rated write endurance is used up.',
	'reallocated-many': 'Many sectors were replaced by spare ones.',
	'reallocated': 'Some sectors were replaced by spare ones: keep an eye on whether the number grows.',
	'wearing': 'Most of its rated write endurance is used.',
	'cable': 'Transfer errors between the disk and the computer: often a loose or worn cable.',
	'hot': 'It runs hot.',
	'old': 'Over 50,000 hours powered on.',
}
// Sections in the order they appear, each shown only when the machine has such sensors
const SECTIONS = [
	{ kind: 'temp', title: 'Temperatures', name: 'Temperature' },
	{ kind: 'fan', title: 'Fans', name: 'Fan' },
	{ kind: 'voltage', title: 'Voltages', name: 'Voltage' },
	{ kind: 'power', title: 'Power', name: 'Power' },
	{ kind: 'current', title: 'Current', name: 'Current' },
]

function storedUnit() {
	try {
		return localStorage.getItem('temperatureFormat') === '°F' ? '°F' : '°C'
	}
	catch (e) {
		return '°C'
	}
}

export default {
	name: 'HardwarePanel',
	compatConfig: { MODE: 3 },
	components: { HistoryStrips },
	data() {
		return {
			open: false,
			loading: false,
			info: null,
			groups: [],
			live: null,
			unit: '°C',
			// null while loading, false without the service on the server
			disks: null,
			range: 24,
			// null while loading, false when the server keeps no history
			history: null,
			// Each disk's temperature, hourly: { times, disks: { id: [°C] } }, null without it
			diskTemps: null,
			appUsage: [],
			appTitles: {},
			colors: COLORS,
			// The device a self-test is being started on
			testing: '',
			autoTests: true,
			savingAutoTests: false,
		}
	},
	computed: {
		sections() {
			return SECTIONS.map((section) => ({
				...section,
				groups: this.groups
					.map((group) => ({ ...group, sensors: group.sensors.filter((s) => s.kind === section.kind && s.value !== null) }))
					.filter((group) => group.sensors.length),
			})).filter((section) => section.groups.length)
		},
		hasExtraSensors() {
			return this.sections.some((section) => section.kind !== 'temp')
		},
		memoryPercent() {
			const memory = this.live?.memory
			return memory?.total ? Math.round((memory.used / memory.total) * 100) : 0
		},
	},
	mounted() {
		this.$EventBus.$on('atrio:open-hardware', this.show)
		window.addEventListener('keydown', this.onKey)
	},
	beforeUnmount() {
		this.$EventBus.$off('atrio:open-hardware', this.show)
		window.removeEventListener('keydown', this.onKey)
		clearInterval(this.timer)
	},
	methods: {
		renderSize,
		// `section`: 'disks' scrolls to the disks once they are there
		async show(section) {
			if (section === 'disks') this.scrollToDisks = true
			if (this.open) return
			this.returnFocus = document.activeElement
			this.open = true
			this.unit = storedUnit()
			this.$nextTick(() => this.$refs.sheet?.focus())
			this.loadDisks()
			this.loadHistory()
			// Machine details and the sensor list are read once per page load
			if (!this.info) {
				this.loading = true
				const [info, groups] = await Promise.all([readStatic(this.$api), discoverSensors(this.$api)])
				this.info = info
				this.groups = groups
				this.loading = false
				this.revealDisks()
			}
			await this.poll()
			this.revealDisks()
			clearInterval(this.timer)
			if (this.open) this.timer = setInterval(this.poll, POLL_MS)
		},
		close() {
			this.open = false
			clearInterval(this.timer)
			this.$nextTick(() => restoreFocus(this.returnFocus))
		},
		onKey(event) {
			if (!this.open) return
			if (event.key === 'Escape') this.close()
			else trapTab(event, this.$refs.sheet)
		},
		async poll() {
			if (this.polling) return
			this.polling = true
			try {
				this.live = await readLive(this.$api, this.groups, this.info?.cpu.threads)
			}
			finally {
				this.polling = false
			}
		},
		async loadHistory() {
			const [rows, diskTemps] = await Promise.all([loadHistory(this.range), loadDiskTemps(this.range)])
			this.history = rows === null ? false : rows
			this.diskTemps = diskTemps
			this.revealDisks()
			this.appUsage = await loadAppUsage()
			if (this.appUsage.length && !Object.keys(this.appTitles).length) {
				try {
					const grid = (await this.$openAPI.appGrid.getAppGrid()).data.data || []
					this.appTitles = Object.fromEntries(grid.map((app) => [app.name, typeof app.title === 'object' ? ice_i18n(app.title) : app.title || app.name]))
				}
				catch (e) {
					// The app's own name then
				}
			}
		},
		setRange(hours) {
			this.range = hours
			this.loadHistory()
		},
		// The strips of the history, in the order of the panel above them
		historyRows() {
			// One hue: each strip is a single measure, named on its left
			const [cpu] = this.colors
			return [
				{ label: this.$t('Processor'), values: this.column('cpu'), format: this.percent, color: cpu, max: 100 },
				{ label: this.$t('Memory'), values: this.column('memory'), format: this.percent, color: cpu, max: 100 },
				{ label: this.$t('Received'), values: this.column('down'), format: this.rate, color: cpu, min: 1024 },
				{ label: this.$t('Sent'), values: this.column('up'), format: this.rate, color: cpu, min: 1024 },
				{ label: this.$t('Processor °C'), values: this.column('cpuTemp'), format: this.degrees, color: cpu, fit: true },
				{ label: this.$t('Hottest disk °C'), values: this.column('diskTemp'), format: this.degrees, color: cpu, fit: true },
			].filter((row) => row.values.some((value) => value !== null))
		},
		// One line per disk that has points, named by its model (and device when two share it)
		diskTempSeries() {
			if (!this.diskTemps || this.diskTemps.times.length < 2 || !this.disks) return []
			const models = this.disks.map((disk) => disk.model)
			return this.disks.filter((disk) => this.diskTemps.disks[diskId(disk)]?.some((value) => value !== null))
				.map((disk) => ({
					label: models.filter((model) => model === disk.model).length > 1 ? `${disk.model} (${disk.device})` : disk.model || disk.device,
					color: this.colors[0],
					values: this.diskTemps.disks[diskId(disk)],
					format: this.degrees,
					fit: true,
				}))
		},
		column(key) {
			return (this.history || []).map((row) => row[key])
		},
		percent(value) {
			return `${Math.round(value)}%`
		},
		rate(value) {
			return `${renderSize(value)}/s`
		},
		degrees(value) {
			return this.temperature(value)
		},
		async loadDisks() {
			try {
				const res = await this.$api.file.getContent(DISKS)
				this.disks = res.data.success === 200 ? JSON.parse(res.data.data).disks || [] : false
			}
			catch (e) {
				this.disks = false
			}
			this.revealDisks()
			if (this.disks) this.loadAutoTests()
		},
		async loadAutoTests() {
			try {
				const res = await this.$api.file.getContent(ALERTS_CONF)
				this.autoTests = !(res.data.success === 200 && /^SELFTEST=0$/m.test(res.data.data || ''))
			}
			catch (e) {
				this.autoTests = true
			}
		},
		// Only this line of alerts.conf changes; the push alert settings keep theirs
		async setAutoTests(on) {
			this.savingAutoTests = true
			try {
				const res = await this.$api.file.getContent(ALERTS_CONF)
				const exists = res.data.success === 200
				const lines = (exists ? res.data.data || '' : '').split('\n').filter((line) => line && !line.startsWith('SELFTEST='))
				lines.push(`SELFTEST=${on ? 1 : 0}`)
				if (!exists) await this.$api.file.create(ALERTS_CONF)
				const saved = await this.$api.file.update(ALERTS_CONF, `${lines.join('\n')}\n`)
				if (saved.data.success !== 200) throw new Error('save')
				this.autoTests = on
			}
			catch (e) {
				this.$buefy.toast.open({ message: this.$t('Could not save the setting'), type: 'is-danger' })
			}
			this.savingAutoTests = false
		},
		canTest(disk) {
			return disk.selftest === 'yes'
		},
		isRunning(disk) {
			return disk.running !== undefined && disk.running !== ''
		},
		// "Short, passed · 3 days ago", from the disk's own power-on hours
		testText(disk) {
			if (this.isRunning(disk)) {
				return Number(disk.running) > 0 ? this.$t('Running, {n}% done', { n: disk.running }) : this.$t('Test running')
			}
			if (!disk.test) return this.$t('None yet')
			const kind = { short: this.$t('Short'), long: this.$t('Long') }[disk.testkind] || this.$t('Other')
			const result = { passed: this.$t('passed'), failed: this.$t('failed'), aborted: this.$t('stopped before the end') }[disk.test] || disk.test
			const hours = Number(disk.hours) - Number(disk.testhours)
			let when = ''
			if (disk.testhours !== '' && hours >= 0) {
				when = hours < 24 ? this.$t('today') : this.$t('{n} days ago', { n: Math.floor(hours / 24) })
			}
			return [`${kind}, ${result}`, when].filter(Boolean).join(' · ')
		},
		runTest(disk, kind) {
			const start = async () => {
				this.testing = disk.device
				try {
					await startDiskTest(disk.device, kind)
					this.$buefy.toast.open({ message: this.$t('Test started: the result shows here when it ends.'), type: 'is-success' })
				}
				catch (e) {
					const running = e.message === 'A test is already running on this disk'
					this.$buefy.toast.open({ message: this.$t(e.message || 'The disk did not start the test'), type: running ? 'is-info' : 'is-danger' })
				}
				this.testing = ''
				this.loadDisks()
			}
			if (kind === 'short') return start()
			this.$buefy.dialog.confirm({
				title: this.$t('Start a long test?'),
				message: this.$t('It reads the whole disk and can take hours on a big one. The disk keeps working meanwhile, a little slower.'),
				confirmText: this.$t('Start'),
				cancelText: this.$t('Cancel'),
				onConfirm: start,
			})
		},
		// Once the charts above them are there too, so that nothing moves the disks after the scroll
		revealDisks() {
			if (!this.scrollToDisks || !this.info || !this.live || this.disks === null || this.history === null) return
			this.scrollToDisks = false
			this.$nextTick(() => setTimeout(() => this.$refs.disks?.scrollIntoView({ block: 'start' }), 150))
		},
		verdict(disk) {
			return this.$t(VERDICTS[disk.verdict] || VERDICTS.unknown)
		},
		verdictLevel(disk) {
			return { good: 'is-ok', watch: 'is-warm', replace: 'is-hot' }[disk.verdict] || ''
		},
		reasons(disk) {
			return (disk.reasons || '').split(' ').filter((reason) => REASONS[reason]).map((reason) => this.$t(REASONS[reason]))
		},
		kind(disk) {
			return { nvme: 'NVMe SSD', ssd: 'SSD', hdd: this.$t('Hard disk') }[disk.kind] || ''
		},
		powerOn(hours) {
			const days = Math.floor(Number(hours) / 24)
			if (days < 60) return this.$t('{n} days', { n: days })
			const years = Math.floor(days / 365)
			const months = Math.floor((days % 365) / 30)
			return years ? this.$t('{years} y, {months} months', { years, months }) : this.$t('{n} months', { n: months })
		},
		// The counters that matter, only when they are not zero
		counters(disk) {
			return [
				['reallocated', 'Replaced sectors'], ['pending', 'Sectors waiting'], ['unc', 'Uncorrectable errors'],
				['media', 'Integrity errors'], ['crc', 'Cable errors'],
			].filter(([key]) => Number(disk[key]) > 0).map(([key, label]) => ({ key, label: this.$t(label), value: disk[key] }))
		},
		toggleUnit() {
			this.unit = this.unit === '°C' ? '°F' : '°C'
			try {
				localStorage.setItem('temperatureFormat', this.unit)
			}
			catch (e) {
				// Private window: the choice lasts until the page closes
			}
		},
		temperature(celsius) {
			return this.unit === '°F' ? `${Math.round((celsius * 9) / 5 + 32)}°F` : `${Math.round(celsius)}°C`
		},
		// ok / warm / hot, from the chip's own limits when it reports them
		level(sensor) {
			const crit = sensor.crit || 95
			const warm = sensor.max && sensor.max < crit ? sensor.max : crit - 15
			return sensor.value >= crit ? 'is-hot' : sensor.value >= warm ? 'is-warm' : 'is-ok'
		},
		value(sensor) {
			switch (sensor.kind) {
				case 'temp': return this.temperature(sensor.value)
				case 'fan': return `${Math.round(sensor.value)} RPM`
				case 'voltage': return `${sensor.value.toFixed(2)} V`
				case 'power': return `${sensor.value.toFixed(1)} W`
				default: return `${sensor.value.toFixed(2)} A`
			}
		},
		uptime(seconds) {
			if (seconds === null || seconds === undefined) return '—'
			const days = Math.floor(seconds / 86400)
			const hours = Math.floor((seconds % 86400) / 3600)
			const minutes = Math.floor((seconds % 3600) / 60)
			return days ? this.$t('{days} d, {hours} h', { days, hours }) : this.$t('{hours} h, {minutes} min', { hours, minutes })
		},
		sensorLabel(sensor, section, group) {
			if (sensor.label) return sensor.label
			const name = this.$t(section.name)
			return group.sensors.length > 1 ? `${name} ${sensor.index}` : name
		},
		frequency(mhz) {
			return mhz >= 1000 ? `${(mhz / 1000).toFixed(2)} GHz` : `${mhz} MHz`
		},
	},
}
</script>

<template>
	<Teleport to="body">
		<transition name="atrio-sheet">
			<div v-if="open" class="atrio-sheet-backdrop" @click.self="close">
				<aside ref="sheet" :aria-label="$t('Hardware')" aria-modal="true" class="atrio-sheet atrio-hardware" role="dialog" tabindex="-1">
					<header class="atrio-sheet-head">
						<span class="atrio-hardware-icon">
							<b-icon icon="chip" pack="mdi" />
						</span>
						<div class="atrio-sheet-title">
							<h2>{{ $t('Hardware') }}</h2>
							<p class="atrio-hardware-sub">{{ info?.machine || info?.hostname || '' }}</p>
						</div>
						<button :aria-label="$t('Close')" class="atrio-icon-button" type="button" @click="close">
							<b-icon icon="close-outline" pack="casa" />
						</button>
					</header>

					<p v-if="loading || !info" class="atrio-config-empty">{{ $t('Loading…') }}</p>

					<div v-else class="atrio-sheet-config">
						<section>
							<h3>{{ $t('System') }}</h3>
							<dl class="atrio-sheet-info">
								<template v-if="info.machine">
									<dt>{{ $t('Machine') }}</dt>
									<dd :title="info.machine">{{ info.machine }}</dd>
								</template>
								<template v-if="info.board && info.board !== info.machine">
									<dt>{{ $t('Motherboard') }}</dt>
									<dd :title="info.board">{{ info.board }}</dd>
								</template>
								<template v-if="info.bios">
									<dt>BIOS</dt>
									<dd :title="info.bios">{{ info.bios }}</dd>
								</template>
								<dt>{{ $t('Operating system') }}</dt>
								<dd>{{ info.os || '—' }}</dd>
								<dt>Kernel</dt>
								<dd class="is-mono">{{ info.kernel || '—' }}</dd>
								<dt>{{ $t('Host name') }}</dt>
								<dd class="is-mono">{{ info.hostname || '—' }}</dd>
								<dt>{{ $t('Uptime') }}</dt>
								<dd>{{ uptime(live?.uptime) }}</dd>
							</dl>
						</section>

						<section>
							<h3>{{ $t('Processor') }}</h3>
							<div v-if="live?.cpu" class="atrio-hardware-meter">
								<div class="atrio-hardware-meter-text">
									<span>{{ $t('In use') }}</span>
									<span>{{ live.cpu.total }}%</span>
								</div>
								<div class="atrio-hardware-bar"><span :style="{ width: `${live.cpu.total}%` }" /></div>
								<ul v-if="live.cpu.cores.length > 1" :aria-label="$t('Usage per core')" class="atrio-hardware-cores">
									<li v-for="(core, i) in live.cpu.cores" :key="i" :title="`${$t('Core')} ${i}: ${core}%`">
										<span :style="{ height: `${Math.max(core, 3)}%` }" />
									</li>
								</ul>
							</div>
							<dl class="atrio-sheet-info">
								<dt>{{ $t('Model') }}</dt>
								<dd :title="info.cpu.model">{{ info.cpu.model || '—' }}</dd>
								<dt>{{ $t('Cores') }}</dt>
								<dd>{{ info.cpu.cores === info.cpu.threads ? info.cpu.cores : $t('{cores} cores, {threads} threads', info.cpu) }}</dd>
								<template v-if="live?.avgMHz">
									<dt>{{ $t('Frequency') }}</dt>
									<dd>{{ frequency(live.avgMHz) }}<span v-if="info.cpu.maxMHz" class="atrio-hardware-muted"> / {{ frequency(info.cpu.maxMHz) }} max</span></dd>
								</template>
								<template v-if="live?.load?.[0] !== null && live?.load?.length">
									<dt>{{ $t('Load average') }}</dt>
									<dd class="is-mono">{{ live.load.map((n) => n?.toFixed(2)).join(' · ') }}</dd>
								</template>
								<template v-if="info.cpu.cache">
									<dt>Cache</dt>
									<dd>{{ info.cpu.cache }}</dd>
								</template>
							</dl>
						</section>

						<section v-if="live?.memory.total">
							<h3>{{ $t('Memory') }}</h3>
							<div class="atrio-hardware-meter">
								<div class="atrio-hardware-meter-text">
									<span>{{ renderSize(live.memory.used) }} / {{ renderSize(live.memory.total) }}</span>
									<span>{{ memoryPercent }}%</span>
								</div>
								<div class="atrio-hardware-bar"><span :style="{ width: `${memoryPercent}%` }" /></div>
							</div>
							<p v-if="live.memory.swapTotal" class="atrio-hardware-muted atrio-hardware-swap">
								Swap: {{ renderSize(live.memory.swapUsed) }} / {{ renderSize(live.memory.swapTotal) }}
							</p>
						</section>

						<section v-if="history !== false">
							<div class="atrio-hardware-section-head">
								<h3>{{ $t('History') }}</h3>
								<div :aria-label="$t('Period')" class="atrio-segmented is-small" role="radiogroup">
									<button v-for="hours in [24, 168]" :key="hours" :aria-checked="range === hours" :class="{ 'is-active': range === hours }" role="radio" type="button" @click="setRange(hours)">
										{{ hours === 24 ? $t('24 hours') : $t('7 days') }}
									</button>
								</div>
							</div>
							<p v-if="history === null" class="atrio-hardware-muted">{{ $t('Loading…') }}</p>
							<template v-else>
								<HistoryStrips :rows="historyRows()" :times="column('time')" />
							</template>
							<template v-if="appUsage.length">
								<h4 class="atrio-hardware-apps-title">{{ $t('Apps now') }}</h4>
								<ul class="atrio-hardware-apps">
									<li v-for="item in appUsage" :key="item.app">
										<span class="atrio-hardware-label">{{ appTitles[item.app] || item.app }}</span>
										<span class="atrio-hardware-app-bar"><span :style="{ width: `${Math.min(100, item.memory / appUsage[0].memory * 100)}%` }" /></span>
										<span class="atrio-hardware-value">{{ renderSize(item.memory * 1048576) }} · {{ item.cpu.toFixed(1) }}% CPU</span>
									</li>
								</ul>
							</template>
						</section>
						<p v-else class="atrio-hardware-muted">{{ $t('Charts of the last days need the latest version of the service on the server. Run the install command once more.') }}</p>

						<section v-if="disks?.length" ref="disks">
							<h3>{{ $t('Disks') }}</h3>
							<div v-for="disk in disks" :key="disk.device" class="atrio-hardware-disk">
								<div class="atrio-hardware-disk-head">
									<span :class="verdictLevel(disk)" class="atrio-hardware-dot" />
									<strong :title="disk.serial ? `${disk.model} · ${disk.serial}` : disk.model">{{ disk.model || disk.device }}</strong>
									<span :class="verdictLevel(disk)" class="atrio-hardware-verdict">{{ verdict(disk) }}</span>
								</div>
								<dl class="atrio-sheet-info">
									<dt>{{ $t('Device') }}</dt>
									<dd>{{ [disk.device, kind(disk), disk.size ? renderSize(Number(disk.size)) : ''].filter(Boolean).join(' · ') }}</dd>
									<template v-if="disk.temp">
										<dt>{{ $t('Temperature') }}</dt>
										<dd>{{ temperature(Number(disk.temp)) }}</dd>
									</template>
									<template v-if="disk.hours">
										<dt>{{ $t('Powered on') }}</dt>
										<dd>{{ powerOn(disk.hours) }}</dd>
									</template>
									<template v-if="disk.used !== '' && disk.used !== undefined">
										<dt>{{ $t('Wear') }}</dt>
										<dd>{{ disk.used }}%</dd>
									</template>
									<template v-if="canTest(disk) || disk.test">
										<dt>{{ $t('Self-test') }}</dt>
										<dd>{{ testText(disk) }}</dd>
									</template>
									<template v-for="counter in counters(disk)" :key="counter.key">
										<dt>{{ counter.label }}</dt>
										<dd>{{ counter.value }}</dd>
									</template>
								</dl>
								<ul v-if="reasons(disk).length" class="atrio-hardware-reasons">
									<li v-for="reason in reasons(disk)" :key="reason">{{ reason }}</li>
								</ul>
								<div v-if="canTest(disk)" class="atrio-hardware-disk-actions">
									<button :disabled="!!testing || isRunning(disk)" class="atrio-config-tag" type="button" @click="runTest(disk, 'short')">
										{{ testing === disk.device ? $t('Starting…') : $t('Short test') }}
									</button>
									<button :disabled="!!testing || isRunning(disk)" class="atrio-config-tag" type="button" @click="runTest(disk, 'long')">
										{{ $t('Long test') }}
									</button>
								</div>
							</div>
							<div v-if="diskTempSeries().length" class="atrio-hardware-disk-chart">
								<h4 class="atrio-hardware-apps-title">{{ range > 24 ? $t('Disk temperatures, last 7 days') : $t('Disk temperatures, last 24 hours') }}</h4>
								<HistoryStrips :rows="diskTempSeries()" :times="diskTemps.times" />
							</div>
							<p class="atrio-hardware-muted">{{ $t('Read from SMART every hour, without waking disks that sleep. A disk that gets worse sends a push alert.') }}</p>
							<label v-if="disks.some(canTest)" class="atrio-hardware-autotest">
								<input :checked="autoTests" :disabled="savingAutoTests" type="checkbox" @change="setAutoTests($event.target.checked)">
								<span>{{ $t('Self-tests on their own: a short one each week and a long one each month, at night') }}</span>
							</label>
						</section>

						<section v-for="section in sections" :key="section.kind">
							<div class="atrio-hardware-section-head">
								<h3>{{ $t(section.title) }}</h3>
								<button v-if="section.kind === 'temp'" :title="$t('Switch °C / °F')" class="atrio-config-tag atrio-hardware-unit" type="button" @click="toggleUnit">
									{{ unit }}
								</button>
							</div>
							<div v-for="group in section.groups" :key="group.id" class="atrio-hardware-group">
								<h4>{{ $t(group.name.split(' · ')[0]) }}<template v-if="group.name.includes(' · ')"> · {{ group.name.split(' · ')[1] }}</template></h4>
								<ul class="atrio-config-list">
									<li v-for="sensor in group.sensors" :key="sensor.id">
										<span v-if="sensor.kind === 'temp'" :class="level(sensor)" class="atrio-hardware-dot" />
										<span class="atrio-hardware-label">{{ sensorLabel(sensor, section, group) }}</span>
										<span class="atrio-hardware-value">{{ value(sensor) }}</span>
									</li>
								</ul>
							</div>
						</section>

						<p v-if="!hasExtraSensors" class="atrio-config-hint">
							{{ $t('This machine does not report fans, voltages or power. They appear here on machines whose sensors expose them.') }}
						</p>
					</div>
				</aside>
			</div>
		</transition>
	</Teleport>
</template>

<style lang="scss">
.atrio-hardware {
	width: min(36rem, calc(100% - 2rem));

	.atrio-sheet-info {
		grid-template-columns: 9rem minmax(0, 1fr);
	}
}

.atrio-hardware-icon {
	display: grid;
	place-items: center;
	width: 3.75rem;
	height: 3.75rem;
	border-radius: 1.125rem;
	background: rgba(34, 211, 238, 0.14);
	color: #a5f3fc;

	.icon {
		width: 2rem;
		height: 2rem;
		font-size: 2rem;
	}
}

.atrio-hardware-sub,
.atrio-hardware-muted {
	color: var(--atrio-text-muted);
	font-size: 0.8125rem;
}

.atrio-hardware-section-head {
	display: flex;
	align-items: center;
	justify-content: space-between;
	margin-bottom: 0.625rem;

	h3 {
		margin-bottom: 0 !important;
	}
}

.atrio-hardware-unit {
	border: 0;
	font: inherit;
	font-size: 0.75rem;
	cursor: pointer;

	&:hover {
		background: rgba(255, 255, 255, 0.14);
	}
}

.atrio-hardware-group + .atrio-hardware-group {
	margin-top: 0.25rem;
}

.atrio-hardware-group h4 {
	margin-top: 0.5rem !important;
}

.atrio-hardware-label {
	flex: 1;
	min-width: 0;
	overflow: hidden;
	text-overflow: ellipsis;
	white-space: nowrap;
}

.atrio-hardware-value {
	font-variant-numeric: tabular-nums;
	font-weight: 600;
}

.atrio-hardware-apps-title {
	margin: 0.5rem 0 0.375rem;
	color: var(--atrio-text);
	font-size: 0.8125rem;
	font-weight: 600;
}

.atrio-hardware-apps {
	margin: 0;
	padding: 0;
	list-style: none;

	li {
		display: grid;
		grid-template-columns: minmax(6rem, 1fr) 4rem auto;
		gap: 0.75rem;
		align-items: center;
		padding: 0.25rem 0;
		font-size: 0.8125rem;
	}
}

.atrio-hardware-app-bar {
	height: 6px;
	overflow: hidden;
	border-radius: 3px;
	background: rgba(255, 255, 255, 0.08);

	span {
		display: block;
		height: 100%;
		border-radius: 3px;
		background: #0aa5c4;
	}
}

.atrio-hardware-disk {
	padding: 0.75rem 0;
	border-bottom: 1px solid rgba(255, 255, 255, 0.06);

	.atrio-sheet-info {
		margin-top: 0.5rem;
	}
}

.atrio-hardware-disk-head {
	display: flex;
	gap: 0.5rem;
	align-items: center;

	strong {
		min-width: 0;
		overflow: hidden;
		color: var(--atrio-text);
		font-size: 0.9375rem;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
}

.atrio-hardware-verdict {
	flex: none;
	margin-left: auto;
	padding: 0.125rem 0.5rem;
	border-radius: 999px;
	background: rgba(255, 255, 255, 0.08);
	color: var(--atrio-text-soft);
	font-size: 0.75rem;

	&.is-ok {
		background: rgba(74, 222, 128, 0.14);
		color: #bbf7d0;
	}

	&.is-warm {
		background: rgba(251, 191, 36, 0.16);
		color: #fde68a;
	}

	&.is-hot {
		background: rgba(248, 113, 113, 0.18);
		color: #fecaca;
	}
}

.atrio-hardware-disk-chart {
	margin-top: 0.75rem;
}

.atrio-hardware-disk-actions {
	display: flex;
	gap: 0.5rem;
	margin-top: 0.625rem;

	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
}

.atrio-hardware-autotest {
	display: flex;
	gap: 0.5rem;
	align-items: flex-start;
	margin-top: 0.5rem;
	color: var(--atrio-text-soft);
	font-size: 0.8125rem;
	cursor: pointer;

	input {
		margin-top: 0.1875rem;
		accent-color: #0aa5c4;
	}
}

.atrio-hardware-reasons {
	margin: 0.5rem 0 0;
	padding-left: 1.125rem;
	color: var(--atrio-text-soft);
	font-size: 0.8125rem;
	list-style: disc;
}

.atrio-hardware-dot {
	flex-shrink: 0;
	width: 0.5rem;
	height: 0.5rem;
	border-radius: 50%;

	&.is-ok {
		background: var(--atrio-ok);
	}

	&.is-warm {
		background: var(--atrio-warn);
	}

	&.is-hot {
		border-radius: 2px;
		background: #f87171;
	}
}

.atrio-hardware-meter-text {
	display: flex;
	justify-content: space-between;
	margin-bottom: 0.375rem;
	font-size: 0.875rem;
	font-variant-numeric: tabular-nums;
}

.atrio-hardware-bar {
	height: 0.5rem;
	overflow: hidden;
	border-radius: 999px;
	background: rgba(255, 255, 255, 0.08);

	span {
		display: block;
		height: 100%;
		border-radius: inherit;
		background: #818cf8;
		transition: width 0.4s ease;
	}
}

.atrio-hardware-swap {
	margin-top: 0.5rem;
}

// One thin column per core, filled from the bottom
.atrio-hardware-cores {
	display: grid;
	grid-template-columns: repeat(auto-fit, minmax(0.875rem, 1fr));
	gap: 0.25rem;
	margin: 0.625rem 0 0.75rem;
	padding: 0;
	list-style: none;

	li {
		display: flex;
		align-items: flex-end;
		height: 1.75rem;
		overflow: hidden;
		border-radius: 3px;
		background: rgba(255, 255, 255, 0.08);
	}

	span {
		display: block;
		width: 100%;
		background: #818cf8;
		transition: height 0.4s ease;
	}
}

.atrio-hardware-meter + .atrio-sheet-info {
	margin-top: 0.75rem;
}
</style>
