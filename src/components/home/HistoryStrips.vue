<script>
// The history (see plugins/history.js) as thin strips, one per measure, on one shared time axis.
// Hovering, or the arrow keys once focused, moves one line across all the strips and shows each
// value at that moment on the left. Each strip has its own scale; the peak is on the right.
export default {
	name: 'HistoryStrips',
	compatConfig: { MODE: 3 },
	props: {
		// Seconds since 1970, one per point
		times: { type: Array, required: true },
		// [{ label, values: [number | null], format(value), color, max? (top of the scale), fit? (scale from the lowest value, for temperatures) }]
		rows: { type: Array, required: true },
	},
	data() {
		return { width: 400, hover: null }
	},
	computed: {
		height() {
			return 30
		},
		start() {
			return this.times[0] || 0
		},
		end() {
			return this.times[this.times.length - 1] || 1
		},
		strips() {
			return this.rows.map((row) => {
				const values = row.values.filter((v) => v !== null && Number.isFinite(v))
				const highest = values.length ? Math.max(...values) : 0
				const lowest = values.length ? Math.min(...values) : 0
				let bottom = 0
				let top = row.max ?? niceCeil(Math.max(highest, row.min || 1))
				if (row.fit && values.length) {
					bottom = Math.max(0, Math.floor((lowest - 5) / 5) * 5)
					top = Math.ceil((highest + 5) / 5) * 5
				}
				const average = values.length ? values.reduce((a, b) => a + b, 0) / values.length : null
				return { ...row, bottom, top: Math.max(top, row.max ?? 0, bottom + 1), highest: values.length ? highest : null, lowest, average, ...this.shapes(row.values, bottom, top) }
			})
		},
		timeTicks() {
			const span = this.end - this.start
			return [this.start, this.start + span / 2, this.end]
		},
		hoverX() {
			return this.hover === null ? null : this.x(this.times[this.hover])
		},
	},
	mounted() {
		this.observer = new ResizeObserver(([entry]) => {
			this.width = Math.max(120, Math.round(entry.contentRect.width))
		})
		this.observer.observe(this.$refs.track)
	},
	beforeUnmount() {
		this.observer?.disconnect()
	},
	methods: {
		x(time) {
			const span = this.end - this.start || 1
			return ((time - this.start) / span) * this.width
		},
		y(value, bottom, top) {
			const ratio = (value - bottom) / ((top - bottom) || 1)
			return 2 + (1 - Math.min(1, Math.max(0, ratio))) * (this.height - 4)
		},
		// The line and the area under it, broken where values are missing
		shapes(values, bottom, top) {
			let line = ''
			let area = ''
			let run = []
			const close = () => {
				if (!run.length) return
				// A point alone between gaps is drawn as a short dash, or it would not show
				if (run.length === 1) run.push([run[0][0] + 2, run[0][1]])
				const points = run.map(([px, py]) => `${px.toFixed(1)},${py.toFixed(1)}`)
				line += `M${points.join('L')}`
				area += `M${run[0][0].toFixed(1)},${this.height}L${points.join('L')}L${run[run.length - 1][0].toFixed(1)},${this.height}Z`
				run = []
			}
			values.forEach((value, index) => {
				if (value === null || !Number.isFinite(value)) return close()
				run.push([this.x(this.times[index]), this.y(value, bottom, top)])
			})
			close()
			return { line, area }
		},
		when(time, full) {
			const locale = this.$i18n.locale?.replace('_', '-')
			const date = new Date(time * 1000)
			const days = (this.end - this.start) > 2 * 86400
			if (full) return date.toLocaleString(locale, { weekday: days ? 'short' : undefined, hour: '2-digit', minute: '2-digit' })
			return days ? date.toLocaleDateString(locale, { weekday: 'short', day: 'numeric' }) : date.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
		},
		shown(strip) {
			const values = strip.values
			let value = null
			if (this.hover !== null) value = values[this.hover]
			else for (let i = values.length - 1; i >= 0 && value === null; i--) value = values[i]
			return value === null || value === undefined ? '—' : strip.format(value)
		},
		move(event) {
			if (!this.times.length) return
			const box = this.$refs.track.getBoundingClientRect()
			if (event.clientX < box.left - 8 || event.clientX > box.right + 8) return
			const at = this.start + ((event.clientX - box.left) / box.width) * (this.end - this.start)
			let best = 0
			this.times.forEach((time, index) => {
				if (Math.abs(time - at) < Math.abs(this.times[best] - at)) best = index
			})
			this.hover = best
		},
		onKey(event) {
			if (!this.times.length) return
			const last = this.times.length - 1
			if (event.key === 'ArrowLeft') this.hover = Math.max(0, (this.hover ?? last + 1) - 1)
			else if (event.key === 'ArrowRight') this.hover = Math.min(last, (this.hover ?? -1) + 1)
			else if (event.key === 'Escape') this.hover = null
			else return
			event.preventDefault()
		},
		summary(strip) {
			if (strip.highest === null) return `${strip.label}: —`
			return `${strip.label}: ${this.$t('min {min}, average {average}, max {max}', { min: strip.format(strip.lowest), average: strip.format(strip.average), max: strip.format(strip.highest) })}`
		},
	},
}

function niceCeil(value) {
	const power = 10 ** Math.floor(Math.log10(value))
	for (const step of [1, 2, 2.5, 5, 10]) {
		if (step * power >= value) return step * power
	}
	return 10 * power
}
</script>

<template>
	<div
		:aria-label="$t('History charts: use the left and right arrows to move through time')" class="atrio-strips" role="group" tabindex="0"
		@blur="hover = null" @keydown="onKey" @pointerdown="move" @pointerleave="hover = null" @pointermove="move"
	>
		<ul class="atrio-strips-summary">
			<li v-for="strip in strips" :key="strip.label">{{ summary(strip) }}</li>
		</ul>
		<div v-for="strip in strips" :key="strip.label" aria-hidden="true" class="atrio-strip">
			<div class="atrio-strip-name">
				<span>{{ strip.label }}</span>
				<strong :class="{ 'is-hover': hover !== null }">{{ shown(strip) }}</strong>
			</div>
			<div class="atrio-strip-track">
				<svg :height="height" :viewBox="`0 0 ${width} ${height}`" :width="width">
					<line :x2="width" :y1="height - 0.5" :y2="height - 0.5" class="atrio-strip-base" x1="0" />
					<path :d="strip.area" :fill="strip.color" class="atrio-strip-area" />
					<path :d="strip.line" :stroke="strip.color" class="atrio-strip-line" />
					<template v-if="hoverX !== null">
						<line :x1="hoverX" :x2="hoverX" :y2="height" class="atrio-strip-cross" y1="0" />
						<circle
							v-if="strip.values[hover] !== null && strip.values[hover] !== undefined"
							:cx="hoverX" :cy="y(strip.values[hover], strip.bottom, strip.top)" :fill="strip.color" class="atrio-strip-dot" r="4"
						/>
					</template>
				</svg>
			</div>
			<div class="atrio-strip-peak">
				<span>{{ $t('peak') }}</span>
				{{ strip.highest === null ? '—' : strip.format(strip.highest) }}
			</div>
		</div>
		<div aria-hidden="true" class="atrio-strip atrio-strip-axis">
			<div />
			<!-- The same column as the strips: its width is theirs -->
			<div ref="track" class="atrio-strip-times">
				<template v-if="hoverX === null">
					<!-- By place: with a single point the three times are the same -->
					<span v-for="(time, index) in timeTicks" :key="index">{{ when(time) }}</span>
				</template>
				<span v-else :class="{ 'is-right': hoverX > width / 2 }" :style="{ left: `${hoverX}px` }" class="atrio-strip-when">{{ when(times[hover], true) }}</span>
			</div>
			<div />
		</div>
		<p v-if="!times.length" class="atrio-strips-empty">{{ $t('No data yet: the server adds a point every 5 minutes.') }}</p>
	</div>
</template>

<style lang="scss">
.atrio-strips {
	margin: 0.25rem 0 1rem;
	border-radius: 0.5rem;
	outline: none;

	&:focus-visible {
		box-shadow: 0 0 0 2px rgba(10, 165, 196, 0.5);
	}
}

.atrio-strips-summary {
	position: absolute;
	width: 1px;
	height: 1px;
	overflow: hidden;
	clip: rect(0 0 0 0);
	white-space: nowrap;
}

.atrio-strip {
	display: grid;
	grid-template-columns: 7.5rem minmax(0, 1fr) 4.75rem;
	gap: 0.75rem;
	align-items: center;
	padding: 0.375rem 0;
	border-bottom: 1px solid rgba(255, 255, 255, 0.05);
}

.atrio-strip-name {
	display: flex;
	flex-direction: column;
	min-width: 0;
	line-height: 1.25;

	span {
		overflow: hidden;
		color: var(--atrio-text-soft);
		font-size: 0.75rem;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	strong {
		color: var(--atrio-text);
		font-size: 0.9375rem;
		font-variant-numeric: tabular-nums;
		font-weight: 600;

		&.is-hover {
			color: #a5f3fc;
		}
	}
}

.atrio-strip-track {
	min-width: 0;

	svg {
		display: block;
		overflow: visible;
	}
}

.atrio-strip-base {
	stroke: rgba(255, 255, 255, 0.08);
	stroke-width: 1;
}

.atrio-strip-area {
	fill-opacity: 0.12;
}

.atrio-strip-line {
	fill: none;
	stroke-width: 2;
	stroke-linecap: round;
	stroke-linejoin: round;
}

.atrio-strip-cross {
	stroke: rgba(255, 255, 255, 0.35);
	stroke-width: 1;
}

.atrio-strip-dot {
	stroke: #111827;
	stroke-width: 2;
}

.atrio-strip-peak {
	color: var(--atrio-text-soft);
	white-space: nowrap;
	font-size: 0.75rem;
	font-variant-numeric: tabular-nums;
	line-height: 1.25;
	text-align: right;

	span {
		display: block;
		color: var(--atrio-text-muted);
		font-size: 0.6875rem;
	}
}

.atrio-strip-axis {
	border-bottom: 0;
}

.atrio-strip-times {
	position: relative;
	display: flex;
	justify-content: space-between;
	min-height: 1rem;
	color: var(--atrio-text-muted);
	font-size: 0.6875rem;
	font-variant-numeric: tabular-nums;
}

.atrio-strip-when {
	position: absolute;
	top: 0;
	color: var(--atrio-text);
	white-space: nowrap;
	transform: translateX(-50%);

	&.is-right {
		transform: translateX(-90%);
	}
}

.atrio-strips-empty {
	color: var(--atrio-text-muted);
	font-size: 0.75rem;
}

@media (max-width: 480px) {
	.atrio-strip {
		grid-template-columns: 6rem minmax(0, 1fr) 4.5rem;
		gap: 0.5rem;
	}
}
</style>
