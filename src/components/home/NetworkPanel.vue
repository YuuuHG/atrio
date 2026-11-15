<script>
// Which apps use the network: now (measured on the server over a few seconds, again while the
// panel is open) and over the last 24 hours. Opened with `$EventBus.$emit('atrio:open-network')`,
// from the Network Status widget. Shares the sheet styles of AppDetailsPanel.
import { ice_i18n } from '@/mixins/base/common-i18n'
import { renderSize } from '@/mixins/file_utils'
import { restoreFocus, trapTab } from '@/plugins/focusTrap'
import { backupsInstalled, measureNetwork } from '@/plugins/appBackup'
import { loadAppTraffic } from '@/plugins/history'

const REFRESH_MS = 6000

export default {
	name: 'NetworkPanel',
	compatConfig: { MODE: 3 },
	data() {
		return { open: false, now: null, day: [], titles: {}, error: '', measuring: false }
	},
	computed: {
		// Apps with their own counters, the busiest first
		apps() {
			return (this.now?.apps || []).filter((a) => !a.host).sort((a, b) => b.down + b.up - (a.down + a.up))
		},
		hostApps() {
			return (this.now?.apps || []).filter((a) => a.host)
		},
		// What the apps above do not explain: the server itself and the apps on its network
		rest() {
			if (!this.now?.server) return null
			const down = Math.max(0, this.now.server.down - this.apps.reduce((sum, a) => sum + a.down, 0))
			const up = Math.max(0, this.now.server.up - this.apps.reduce((sum, a) => sum + a.up, 0))
			return { down, up }
		},
		busiest() {
			return Math.max(1, ...this.apps.map((a) => a.down + a.up), this.rest ? this.rest.down + this.rest.up : 0)
		},
		dayApps() {
			return this.day.filter((a) => !a.host).sort((a, b) => b.down + b.up - (a.down + a.up))
		},
		dayBusiest() {
			return Math.max(1, ...this.dayApps.map((a) => a.down + a.up))
		},
	},
	mounted() {
		this.$EventBus.$on('atrio:open-network', this.show)
		window.addEventListener('keydown', this.onKey)
	},
	beforeUnmount() {
		this.$EventBus.$off('atrio:open-network', this.show)
		window.removeEventListener('keydown', this.onKey)
		clearTimeout(this.timer)
	},
	methods: {
		renderSize,
		async show() {
			if (this.open) return
			this.returnFocus = document.activeElement
			this.open = true
			this.error = ''
			this.$nextTick(() => this.$refs.sheet?.focus())
			this.loadTitles()
			this.day = await loadAppTraffic()
			if (!(await backupsInstalled())) {
				this.error = this.$t('This needs the service on the server. Run the install command on the server.')
				return
			}
			this.measure()
		},
		close() {
			this.open = false
			clearTimeout(this.timer)
			this.$nextTick(() => restoreFocus(this.returnFocus))
		},
		onKey(event) {
			if (!this.open) return
			if (event.key === 'Escape') this.close()
			else trapTab(event, this.$refs.sheet)
		},
		async loadTitles() {
			try {
				const grid = (await this.$openAPI.appGrid.getAppGrid()).data.data || []
				this.titles = Object.fromEntries(grid.map((app) => [app.name, typeof app.title === 'object' ? ice_i18n(app.title) : app.title || app.name]))
			}
			catch (e) {
				// The apps' own names then
			}
		},
		async measure() {
			if (!this.open) return
			this.measuring = true
			try {
				this.now = await measureNetwork()
				this.error = ''
			}
			catch (e) {
				this.error = e.message === 'Unknown request'
					? this.$t('This needs the latest version of the service on the server. Run the install command once more.')
					: this.$t(e.message)
			}
			finally {
				this.measuring = false
			}
			if (this.open && !this.error) this.timer = setTimeout(this.measure, REFRESH_MS)
		},
		title(app) {
			return this.titles[app] || app
		},
		rate(bytes) {
			return `${renderSize(bytes)}/s`
		},
		width(item, top) {
			return `${Math.max(2, ((item.down + item.up) / top) * 100)}%`
		},
	},
}
</script>

<template>
	<Teleport to="body">
		<transition name="atrio-sheet">
			<div v-if="open" class="atrio-sheet-backdrop" @click.self="close">
				<aside ref="sheet" :aria-label="$t('Network detail')" aria-modal="true" class="atrio-sheet atrio-network" role="dialog" tabindex="-1">
					<header class="atrio-sheet-head">
						<span class="atrio-network-icon"><b-icon icon="swap-vertical" pack="mdi" /></span>
						<div class="atrio-sheet-title">
							<h2>{{ $t('Network detail') }}</h2>
							<p class="atrio-network-sub">{{ $t('Which apps are receiving and sending data') }}</p>
						</div>
						<button :aria-label="$t('Close')" class="atrio-icon-button" type="button" @click="close">
							<b-icon icon="close-outline" pack="casa" />
						</button>
					</header>

					<div class="atrio-sheet-config">
						<section>
							<h3>{{ $t('Now') }} <span v-if="measuring && now" class="atrio-network-live" /></h3>
							<p v-if="error" class="atrio-network-error" role="alert">{{ error }}</p>
							<p v-else-if="!now" class="atrio-config-empty">{{ $t('Measuring…') }}</p>
							<ul v-else class="atrio-network-list" aria-live="polite">
								<li v-for="item in apps" :key="item.app">
									<span class="atrio-network-name">{{ title(item.app) }}</span>
									<span class="atrio-network-bar"><span :style="{ width: width(item, busiest) }" /></span>
									<span class="atrio-network-value"><b-icon icon="arrow-down" pack="mdi" size="is-12" />{{ rate(item.down) }} <b-icon icon="arrow-up" pack="mdi" size="is-12" />{{ rate(item.up) }}</span>
								</li>
								<li v-if="rest">
									<span class="atrio-network-name">{{ hostApps.length ? $t('The server and apps on its network') : $t('The server itself') }}</span>
									<span class="atrio-network-bar is-rest"><span :style="{ width: width(rest, busiest) }" /></span>
									<span class="atrio-network-value"><b-icon icon="arrow-down" pack="mdi" size="is-12" />{{ rate(rest.down) }} <b-icon icon="arrow-up" pack="mdi" size="is-12" />{{ rate(rest.up) }}</span>
								</li>
							</ul>
							<p v-if="hostApps.length" class="atrio-network-note">
								{{ $t('{apps} use the network of the server itself, so their traffic is in the line above with the rest of the server.', { apps: hostApps.map((a) => title(a.app)).join(', ') }) }}
							</p>
							<p class="atrio-network-note">{{ $t('Measured on the server every few seconds while this is open. Traffic between apps, for example through a reverse proxy, counts for both.') }}</p>
						</section>

						<section v-if="dayApps.length">
							<h3>{{ $t('Last 24 hours') }}</h3>
							<ul class="atrio-network-list">
								<li v-for="item in dayApps" :key="item.app">
									<span class="atrio-network-name">{{ title(item.app) }}</span>
									<span class="atrio-network-bar"><span :style="{ width: width(item, dayBusiest) }" /></span>
									<span class="atrio-network-value"><b-icon icon="arrow-down" pack="mdi" size="is-12" />{{ renderSize(item.down) }} <b-icon icon="arrow-up" pack="mdi" size="is-12" />{{ renderSize(item.up) }}</span>
								</li>
							</ul>
						</section>
					</div>
				</aside>
			</div>
		</transition>
	</Teleport>
</template>

<style lang="scss">
.atrio-network {
	width: min(36rem, calc(100% - 2rem));
}

.atrio-network-icon {
	display: grid;
	place-items: center;
	width: 3.75rem;
	height: 3.75rem;
	border-radius: 1.125rem;
	background: rgba(10, 165, 196, 0.16);
	color: #a5f3fc;

	.icon {
		width: 2rem;
		height: 2rem;
		font-size: 2rem;
	}
}

.atrio-network-sub,
.atrio-network-note {
	color: var(--atrio-text-muted);
	font-size: 0.8125rem;
}

.atrio-network-note {
	margin-top: 0.5rem;
	font-size: 0.75rem;
}

.atrio-network-error {
	padding: 0.5rem 0.75rem;
	border-radius: 0.5rem;
	background: rgba(248, 113, 113, 0.15);
	color: #fecaca;
	font-size: 0.8125rem;
}

.atrio-network-live {
	display: inline-block;
	width: 0.5rem;
	height: 0.5rem;
	margin-left: 0.375rem;
	border-radius: 50%;
	background: #0aa5c4;
	vertical-align: middle;
	animation: atrio-network-pulse 1s ease-in-out infinite alternate;
}

@keyframes atrio-network-pulse {
	to { opacity: 0.3; }
}

.atrio-network-list {
	margin: 0;
	padding: 0;
	list-style: none;

	li {
		display: grid;
		grid-template-columns: minmax(7rem, 1fr) 5rem auto;
		gap: 0.75rem;
		align-items: center;
		padding: 0.375rem 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		font-size: 0.8125rem;
	}
}

.atrio-network-name {
	min-width: 0;
	overflow: hidden;
	color: var(--atrio-text);
	text-overflow: ellipsis;
	white-space: nowrap;
}

.atrio-network-bar {
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

	&.is-rest span {
		background: #64748b;
	}
}

.atrio-network-value {
	color: var(--atrio-text-soft);
	font-variant-numeric: tabular-nums;
	white-space: nowrap;

	.icon {
		margin: 0 0.125rem 0 0.375rem;
		color: var(--atrio-text-muted);
	}
}

@media (max-width: 480px) {
	.atrio-network-list li {
		grid-template-columns: 1fr auto;

		.atrio-network-bar {
			display: none;
		}
	}
}
</style>
