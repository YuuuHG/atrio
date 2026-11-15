<template>
	<div class="widget has-text-white clock is-relative">
		<div class="blur-background"></div>

		<div class="network widget-content">
			<!-- Header Start -->
			<div class="widget-header is-flex mr-0">
				<div class="widget-title is-flex-grow-1">
					{{ $t('Network Status') }}
				</div>
				<button :aria-label="$t('Network detail')" :title="$t('Network detail')" class="widget-icon-button atrio-widget-button is-flex-shrink-0 mr-1" type="button" @click="$EventBus.$emit('atrio:open-network')">
					<b-icon custom-size="mdi-18px" icon="swap-vertical" pack="mdi"></b-icon>
				</button>
				<div class="is-flex-shrink-0">
					<b-dropdown v-if="initNetwork.length > 0" v-model="networkId" :mobile-modal="false" animation="fade1"
						aria-role="list" class="netowrk-dropdown" position="is-bottom-left">
						<template #trigger="{ active }">
							<b-button :icon-right="active ? 'up-outline' : 'down-outline'"
								:label="initNetwork[networkId].name" icon-pack="casa" type="is-primary" />
						</template>
						<b-dropdown-item v-for="(item, index) in initNetwork" :key="'net' + index" :value="index"
							aria-role="listitem">
							{{ item.name }}
						</b-dropdown-item>
					</b-dropdown>
				</div>
			</div>
			<!-- Header End -->
			<!-- Atrio: the numbers open the network detail too -->
			<div :aria-label="$t('Network detail')" class="atrio-metrics atrio-network-open" role="button" tabindex="0" @click="$EventBus.$emit('atrio:open-network')" @keydown.enter.space.prevent="$EventBus.$emit('atrio:open-network')">
				<div class="atrio-metric">
					<div class="atrio-metric-value">
						<span class="atrio-metric-label">Upload</span>
						<span class="atrio-metric-number">{{ renderSize(currentUpSpeed * 1024) }}/s</span>
					</div>
					<Sparkline :capacity="60" :values="upHistory" color="#22D3EE" />
				</div>
				<div class="atrio-metric">
					<div class="atrio-metric-value">
						<span class="atrio-metric-label">Download</span>
						<span class="atrio-metric-number">{{ renderSize(currentDownSpeed * 1024) }}/s</span>
					</div>
					<Sparkline :capacity="60" :values="downHistory" color="#6EE7B7" />
				</div>
				<!-- Atrio: the app that used the network most in the last 5 minutes (atrio-alerts) -->
				<div v-if="busiest" class="atrio-network-busiest">
					<img v-if="busiestIcon" :src="busiestIcon" alt="" @error="busiestIcon = ''">
					<b-icon v-else icon="application-outline" pack="mdi" size="is-16" />
					<span class="atrio-network-busiest-name">{{ busiestTitle }}</span>
					<span class="atrio-network-busiest-rate">
						<b-icon icon="arrow-down" pack="mdi" size="is-12" />{{ renderSize(busiest.down) }}/s
						<b-icon icon="arrow-up" pack="mdi" size="is-12" />{{ renderSize(busiest.up) }}/s
					</span>
				</div>
				<p v-if="busiest" class="atrio-network-busiest-note">{{ $t('Most active app in the last 5 minutes') }}</p>
			</div>
		</div>
	</div>
</template>

<script>
import Sparkline from '@/components/widgets/Sparkline.vue'
import { ice_i18n } from '@/mixins/base/common-i18n'
import { loadBusiestApp } from '@/plugins/history'
import { mixin } from '@/mixins/mixin';

export default {
	mixins: [mixin],
	// eslint-disable-next-line vue/multi-word-component-names
	name: 'network',
	icon: "network-outline",
	title: "Network Status",
	initShow: true,
	components: {
		Sparkline,
	},
	data() {
		return {
			initNetwork: [],
			networkId: 0,
			networks: [],
			currentUpSpeed: 0,
			currentDownSpeed: 0,
			// Atrio: the app with the most traffic, from the server's 5-minute samples
			busiest: null,
			busiestTitle: '',
			busiestIcon: '',
		}
	},
	mounted() {
		this.loadBusiest()
		this.busiestTimer = setInterval(this.loadBusiest, 60000)
	},
	beforeUnmount() {
		clearInterval(this.busiestTimer)
	},
	created() {
		this.initNetwork = this.$store.state.hardwareInfo.net

		// select the network last time
		const saved = Number(localStorage.getItem('networkId'))
		if (Number.isInteger(saved) && saved >= 0 && saved < (this.initNetwork?.length || 0)) this.networkId = saved

	},

	computed: {
		upHistory() {
			return (this.networks[this.networkId]?.[0]?.data || []).map(Number)
		},
		downHistory() {
			return (this.networks[this.networkId]?.[1]?.data || []).map(Number)
		},
	},

	watch: {
		networkId(val, oldVal) {
			if (val !== oldVal) {
				localStorage.setItem('networkId', val)
			}
		}
	},

	methods: {
		async loadBusiest() {
			const busiest = await loadBusiestApp()
			if (busiest && busiest.app !== this.busiest?.app) {
				try {
					const app = ((await this.$openAPI.appGrid.getAppGrid()).data.data || []).find((item) => item.name === busiest.app)
					this.busiestTitle = app ? (typeof app.title === 'object' ? ice_i18n(app.title) : app.title || busiest.app) : busiest.app
					this.busiestIcon = app?.icon || ''
				}
				catch (e) {
					this.busiestTitle = busiest.app
					this.busiestIcon = ''
				}
			}
			this.busiest = busiest
		},
		buildDatas(data) {
			if (data.length == 0) {
				return
			}
			data.forEach((el, index) => {
				if (this.networks[index] === undefined) {
					this.networks[index] = [
						{
							name: 'Up',
							data: ["0"],
							cacheData: 0,
							cacheTime: 0
						},
						{
							name: 'Down',
							data: ["0"],
							cacheData: 0,
							cacheTime: 0
						}
					]
				}
				// Send Data
				if (this.networks[index][0].data.length >= 60) {
					this.networks[index][0].data.shift()
				}
				if (this.networks[index][0].cacheData > 0) {
					const timeGap = this.networks[index][0].cacheTime == 0 ? 2 : el.time - this.networks[index][0].cacheTime
					this.networks[index][0].data.push(this.covertToKB((el.bytesSent - this.networks[index][0].cacheData) / timeGap))
				}
				this.networks[index][0].cacheData = el.bytesSent;
				this.networks[index][0].cacheTime = el.time;

				// RecvData
				if (this.networks[index][1].data.length >= 60) {
					this.networks[index][1].data.shift()
				}
				if (this.networks[index][1].cacheData > 0) {
					const timeGap = this.networks[index][1].cacheTime == 0 ? 2 : el.time - this.networks[index][1].cacheTime
					this.networks[index][1].data.push(this.covertToKB((el.bytesRecv - this.networks[index][1].cacheData) / timeGap))
				}
				this.networks[index][1].cacheData = el.bytesRecv;
				this.networks[index][1].cacheTime = el.time;
			});
			this.networkId = this.networkId > this.networks.length - 1 ? 0 : this.networkId
			if (this.networks) {
				const upSpeed = this.networks[this.networkId][0].data[this.networks[this.networkId][0].data.length - 1]
				const downSpeed = this.networks[this.networkId][1].data[this.networks[this.networkId][1].data.length - 1]
				this.currentUpSpeed = isNaN(upSpeed) ? 0 : upSpeed
				this.currentDownSpeed = isNaN(downSpeed) ? 0 : downSpeed
			}
		},
		covertToKB(bytes) {
			return (bytes / 1024).toFixed(0) > 0 ? (bytes / 1024).toFixed(0) : 0;
		}
	},
	sockets: {
		// sys_net(data) {
		// 	this.initNetwork = data.data
		// 	this.buildDatas(this.initNetwork)
		// },
		"casaos:system:utilization"(res) {
			let data = res.Properties
			this.initNetwork = JSON.parse(data.sys_net)
			this.buildDatas(this.initNetwork)
		}
	}
}
</script>

<style lang="scss" scoped>
.network {
	position: relative;
	z-index: 10;

	.up {
		color: rgb(0, 143, 251);
	}

	.down {
		color: rgb(0, 227, 150);
	}

	.chart-container {
		height: 130px;
		overflow: hidden;
		margin: 0 -0.875rem;
	}
}
</style>

<style lang="scss">
.up.is-small,
.down.is-small {
	.mdi {
		font-size: 1rem;
	}
}

.network {
	.netowrk-dropdown {
		.button {
			margin: 0;
			padding: 0;
			height: initial;
			background-color: transparent;
			font-weight: bold;
			font-size: 0.875rem;
			position: relative;
			z-index: 200;
			outline: none;
			border: 0;
			color: $grey-100;

			&:focus:not(:active) {
				box-shadow: 0 0 0 0 !important;
			}

			&:hover,
			&:active {
				outline: none;
				background-color: transparent;
			}

			span {
				display: -webkit-box;
				-webkit-box-orient: vertical;
				-webkit-line-clamp: 1;
				overflow: hidden;
				max-width: 5rem;
			}

			.icon {
				font-size: 1.25rem !important;
				height: 1.5rem;
				line-height: 1.5rem;
				color: $grey-100;

				&:last-child:not(:first-child) {
					margin-right: 0;
				}
			}
		}

		.dropdown-menu {
			min-width: 5rem;

			.dropdown-content {
				max-width: 7rem;
				border-radius: 10px;
				padding: 4px !important;
				background: rgba(0, 0, 0, 0.8);
				backdrop-filter: blur(1rem);

				.dropdown-divider {
					margin: 4px;
				}

				.dropdown-item {
					padding: 0.25rem 0.5rem 0.25rem 0.5rem;
					border-radius: 5px;
					transition: all 0.25s;
					overflow: hidden;
					white-space: nowrap;
					text-overflow: ellipsis;
					color: #fff;
					font-size: 0.75rem;
					margin-bottom: 0.25rem;

					&:last-child {
						margin-bottom: 0;
					}

					&:hover {
						background: rgba(0, 0, 0, 0.2) !important;
					}

					&.is-active {
						background: rgba(0, 0, 0, 0.2) !important;
					}
				}
			}
		}
	}
}

.atrio-network-open {
	border-radius: 0.75rem;
	cursor: pointer;

	&:hover {
		background: rgba(255, 255, 255, 0.04);
	}
}

// The detail button, like the hardware button of the System Status widget
.atrio-widget-button {
	display: grid;
	place-items: center;
	padding: 0;
	border: 0;
	border-radius: 0.375rem;
	background: transparent;
	color: inherit;
	cursor: pointer;

	&:hover {
		background: rgba(255, 255, 255, 0.1);
	}
}

.atrio-network-busiest {
	display: flex;
	gap: 0.5rem;
	align-items: center;
	margin-top: 0.625rem;
	padding-top: 0.625rem;
	border-top: 1px solid rgba(255, 255, 255, 0.08);
	font-size: 0.8125rem;

	img,
	.icon {
		flex: none;
		width: 1.25rem;
		height: 1.25rem;
		border-radius: 0.375rem;
		object-fit: cover;
	}
}

.atrio-network-busiest-name {
	min-width: 0;
	overflow: hidden;
	color: var(--atrio-text);
	text-overflow: ellipsis;
	white-space: nowrap;
}

.atrio-network-busiest-rate {
	flex: none;
	margin-left: auto;
	color: var(--atrio-text-soft);
	font-variant-numeric: tabular-nums;

	.icon {
		width: auto;
		height: auto;
		margin: 0 0.125rem 0 0.375rem;
		color: var(--atrio-text-muted);
	}
}

.atrio-network-busiest-note {
	margin-top: 0.125rem;
	color: var(--atrio-text-muted);
	font-size: 0.6875rem;
}
</style>