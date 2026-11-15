<script>
// A line chart of a history (see plugins/history.js): one or two series over time, one y axis,
// a crosshair and tooltip on hover, a legend when there are two series, and a text summary for
// screen readers. Plain SVG, sized to its box.
export default {
	name: 'HistoryChart',
	compatConfig: { MODE: 3 },
	props: {
		title: { type: String, required: true },
		// Seconds since 1970, one per point
		times: { type: Array, required: true },
		// [{ label, color, values: [number | null] }]
		series: { type: Array, required: true },
		// Formats a value for the axis and the tooltip
		format: { type: Function, default: (value) => String(Math.round(value)) },
		// The top of the axis at least this (100 for percentages)
		min: { type: Number, default: 0 },
		max: { type: Number, default: null },
	},
	data() {
		return { width: 600, hover: null }
	},
	computed: {
		height() {
			return 132
		},
		pad() {
			return { left: 44, right: 8, top: 8, bottom: 20 }
		},
		top() {
			const values = this.series.flatMap((s) => s.values).filter((v) => v !== null && Number.isFinite(v))
			const highest = values.length ? Math.max(...values) : 0
			if (this.max !== null) return Math.max(this.max, highest)
			return niceCeil(Math.max(highest, this.min || 1))
		},
		start() {
			return this.times[0] || 0
		},
		end() {
			return this.times[this.times.length - 1] || 1
		},
		paths() {
			return this.series.map((s) => {
				let d = ''
				let drawing = false
				s.values.forEach((value, index) => {
					if (value === null || !Number.isFinite(value)) {
						drawing = false
						return
					}
					d += `${drawing ? 'L' : 'M'}${this.x(this.times[index]).toFixed(1)},${this.y(value).toFixed(1)}`
					drawing = true
				})
				return d
			})
		},
		ticks() {
			return [0, this.top / 2, this.top]
		},
		timeTicks() {
			const span = this.end - this.start
			return [this.start, this.start + span / 2, this.end]
		},
		// For screen readers and the hover-less: the range of each series
		summary() {
			return this.series.map((s) => {
				const values = s.values.filter((v) => v !== null && Number.isFinite(v))
				if (!values.length) return `${s.label}: —`
				const average = values.reduce((a, b) => a + b, 0) / values.length
				return `${s.label}: ${this.$t('min {min}, average {average}, max {max}', { min: this.format(Math.min(...values)), average: this.format(average), max: this.format(Math.max(...values)) })}`
			}).join('. ')
		},
		tooltip() {
			if (this.hover === null) return null
			const index = this.hover
			return {
				left: this.x(this.times[index]),
				time: this.when(this.times[index], true),
				rows: this.series.map((s) => ({ label: s.label, color: s.color, value: s.values[index], y: s.values[index] === null ? null : this.y(s.values[index]) })),
			}
		},
	},
	mounted() {
		this.observer = new ResizeObserver(([entry]) => {
			this.width = Math.max(240, Math.round(entry.contentRect.width))
		})
		this.observer.observe(this.$refs.box)
	},
	beforeUnmount() {
		this.observer?.disconnect()
	},
	methods: {
		x(time) {
			const span = this.end - this.start || 1
			return this.pad.left + ((time - this.start) / span) * (this.width - this.pad.left - this.pad.right)
		},
		y(value) {
			return this.pad.top + (1 - value / (this.top || 1)) * (this.height - this.pad.top - this.pad.bottom)
		},
		when(time, full) {
			const locale = this.$i18n.locale?.replace('_', '-')
			const date = new Date(time * 1000)
			const days = (this.end - this.start) > 2 * 86400
			if (full) return date.toLocaleString(locale, { weekday: days ? 'short' : undefined, hour: '2-digit', minute: '2-digit' })
			return days ? date.toLocaleDateString(locale, { weekday: 'short', day: 'numeric' }) : date.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
		},
		move(event) {
			if (!this.times.length) return
			const box = this.$refs.svg.getBoundingClientRect()
			const at = this.start + ((event.clientX - box.left - this.pad.left) / (box.width - this.pad.left - this.pad.right)) * (this.end - this.start)
			let best = 0
			this.times.forEach((time, index) => {
				if (Math.abs(time - at) < Math.abs(this.times[best] - at)) best = index
			})
			this.hover = best
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
	<figure ref="box" class="atrio-chart">
		<figcaption>
			<span class="atrio-chart-title">{{ title }}</span>
			<span v-if="series.length > 1" class="atrio-chart-legend">
				<span v-for="s in series" :key="s.label"><i :style="{ background: s.color }" />{{ s.label }}</span>
			</span>
		</figcaption>
		<svg
			ref="svg" :aria-label="`${title}. ${summary}`" :height="height" :viewBox="`0 0 ${width} ${height}`" :width="width"
			role="img" @mouseleave="hover = null" @mousemove="move"
		>
			<g class="atrio-chart-grid">
				<template v-for="tick in ticks" :key="tick">
					<line :x1="pad.left" :x2="width - pad.right" :y1="y(tick)" :y2="y(tick)" />
					<text :x="pad.left - 6" :y="y(tick) + 4" text-anchor="end">{{ format(tick) }}</text>
				</template>
				<text v-for="(time, index) in timeTicks" :key="time" :text-anchor="['start', 'middle', 'end'][index]" :x="x(time)" :y="height - 4">{{ when(time) }}</text>
			</g>
			<path v-for="(d, index) in paths" :key="index" :d="d" :stroke="series[index].color" class="atrio-chart-line" />
			<g v-if="tooltip">
				<line :x1="tooltip.left" :x2="tooltip.left" :y1="pad.top" :y2="height - pad.bottom" class="atrio-chart-cross" />
				<template v-for="row in tooltip.rows" :key="row.label">
					<circle v-if="row.y !== null" :cx="tooltip.left" :cy="row.y" :fill="row.color" class="atrio-chart-dot" r="4" />
				</template>
			</g>
		</svg>
		<div v-if="tooltip" :class="{ 'is-left': tooltip.left > width / 2 }" :style="{ left: `${tooltip.left}px` }" class="atrio-chart-tip">
			<strong>{{ tooltip.time }}</strong>
			<span v-for="row in tooltip.rows" :key="row.label"><i :style="{ background: row.color }" />{{ row.label }}: {{ row.value === null ? '—' : format(row.value) }}</span>
		</div>
		<p v-if="!times.length" class="atrio-chart-empty">{{ $t('No data yet: the server adds a point every 5 minutes.') }}</p>
	</figure>
</template>

<style lang="scss">
.atrio-chart {
	position: relative;
	margin: 0 0 1rem;

	figcaption {
		display: flex;
		flex-wrap: wrap;
		gap: 0.25rem 0.75rem;
		align-items: baseline;
		justify-content: space-between;
		margin-bottom: 0.25rem;
	}

	svg {
		display: block;
		max-width: 100%;
		overflow: visible;
	}
}

.atrio-chart-title {
	color: var(--atrio-text);
	font-size: 0.8125rem;
	font-weight: 600;
}

.atrio-chart-legend {
	display: flex;
	gap: 0.75rem;
	color: var(--atrio-text-soft);
	font-size: 0.75rem;

	i {
		display: inline-block;
		width: 0.75rem;
		height: 2px;
		margin-right: 0.375rem;
		vertical-align: middle;
		border-radius: 1px;
	}
}

.atrio-chart-grid {
	line {
		stroke: rgba(255, 255, 255, 0.07);
		stroke-width: 1;
	}

	text {
		fill: var(--atrio-text-muted);
		font-size: 10px;
		font-variant-numeric: tabular-nums;
	}
}

.atrio-chart-line {
	fill: none;
	stroke-width: 2;
	stroke-linecap: round;
	stroke-linejoin: round;
}

.atrio-chart-cross {
	stroke: rgba(255, 255, 255, 0.25);
	stroke-width: 1;
}

.atrio-chart-dot {
	stroke: #111827;
	stroke-width: 2;
}

.atrio-chart-tip {
	position: absolute;
	top: 1.25rem;
	z-index: 1;
	display: flex;
	flex-direction: column;
	gap: 0.125rem;
	padding: 0.375rem 0.5rem;
	border-radius: 0.5rem;
	background: rgba(2, 6, 23, 0.92);
	box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
	color: var(--atrio-text);
	font-size: 0.75rem;
	white-space: nowrap;
	transform: translateX(0.75rem);
	pointer-events: none;

	&.is-left {
		transform: translateX(calc(-100% - 0.75rem));
	}

	strong {
		color: var(--atrio-text-soft);
		font-weight: 600;
	}

	i {
		display: inline-block;
		width: 0.5rem;
		height: 0.5rem;
		margin-right: 0.375rem;
		border-radius: 50%;
	}
}

.atrio-chart-empty {
	color: var(--atrio-text-muted);
	font-size: 0.75rem;
}
</style>
