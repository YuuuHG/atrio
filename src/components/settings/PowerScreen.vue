<script>
// Full-page screen while the server restarts or shuts down, in the style of the Atrio update screen
// (it shares its card and step styles, from AtrioUpdateScreen.vue, always on the home page).
// It watches the server go down and come back: after a restart the page reloads by itself as soon
// as CasaOS answers again; after a shutdown it says when the power can be cut.
import api from '@/service/api.js'
import { trapTab } from '@/plugins/focusTrap'

const POLL_MS = 3000
// The server is told to restart, then takes a moment to stop answering
const FIRST_POLL_MS = 5000
// No answer within this time counts as down (a request to a server that is off can hang)
const ANSWER_MS = 4000
// After this long, say that it takes longer than usual
const SLOW_MS = 5 * 60 * 1000
// The web server stops among the first services on a shutdown: Docker can take up to 90 seconds more to
// stop the apps, then the disks are written and unmounted. Off only once it has been silent that long.
const OFF_AFTER_MS = 90 * 1000

export default {
	name: 'PowerScreen',
	compatConfig: { MODE: 3 },
	props: {
		// 'restart' or 'shutdown'
		kind: { type: String, required: true },
	},
	emits: ['close'],
	data() {
		return { down: false, downAt: 0, back: false, slow: false, started: Date.now(), now: Date.now() }
	},
	computed: {
		restart() {
			return this.kind === 'restart'
		},
		off() {
			return !this.restart && this.down && this.now - this.downAt >= OFF_AFTER_MS
		},
		steps() {
			return this.restart
				? [
					{ label: 'The server stops', state: this.down ? 'is-done' : 'is-active' },
					{ label: 'It starts again', state: this.back ? 'is-done' : this.down ? 'is-active' : '' },
					{ label: 'Atrio comes back', state: this.back ? 'is-active' : '' },
				]
				: [
					{ label: 'Apps and services stop', state: this.off ? 'is-done' : 'is-active' },
					{ label: 'The server is off', state: this.off ? 'is-done' : '' },
				]
		},
		elapsed() {
			const seconds = Math.floor((this.now - this.started) / 1000)
			return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
		},
		note() {
			if (this.off) return this.$t('The server is off. You can cut the power now.')
			if (this.slow) {
				return this.restart
					? this.$t('This takes longer than usual. Once the server is on again, reload this page.')
					: this.$t('The server still answers. Wait a little longer before cutting the power.')
			}
			return this.restart
				? this.$t('It usually takes a minute or two. The page reloads by itself when the server is back.')
				: this.$t('Wait until this screen says the server is off before cutting the power.')
		},
	},
	mounted() {
		this.$nextTick(() => this.$refs.card?.focus())
		this.clock = setInterval(() => (this.now = Date.now()), 1000)
		this.timer = setTimeout(this.poll, FIRST_POLL_MS)
	},
	beforeUnmount() {
		clearInterval(this.clock)
		clearTimeout(this.timer)
	},
	methods: {
		trapTab,
		reload() {
			location.reload()
		},
		async answers() {
			try {
				const res = await Promise.race([
					api.users.getUserStatus(),
					new Promise((resolve, reject) => setTimeout(() => reject(new Error('timeout')), ANSWER_MS)),
				])
				return Boolean(res?.data?.data)
			}
			catch (e) {
				return false
			}
		},
		async poll() {
			const up = await this.answers()
			if (!up && !this.down) {
				this.down = true
				this.downAt = Date.now()
			}
			// Back after going down: the new page needs the server's fresh state
			if (up && this.down && this.restart) {
				this.back = true
				setTimeout(() => location.reload(), 1500)
				return
			}
			// Shutting down and answering again: it was only slow to answer, the server is not off yet
			if (up && !this.restart) this.down = false
			if (this.off) {
				clearInterval(this.clock)
				return
			}
			// "Still answers" only while it does
			this.slow = Date.now() - this.started > SLOW_MS && (this.restart || !this.down)
			this.timer = setTimeout(this.poll, POLL_MS)
		},
	},
}
</script>

<template>
	<Teleport to="body">
		<div class="atrio-update-screen" @keydown.tab="trapTab($event, $refs.card)">
			<div ref="card" :aria-label="restart ? $t('Restarting now') : $t('Now shutting down')" aria-live="polite" aria-modal="true" class="atrio-update-card" role="dialog" tabindex="-1">
				<span :class="{ 'is-off': off }" class="atrio-power-mark">
					<b-icon :icon="restart ? 'restart' : 'power'" custom-size="mdi-28px" pack="mdi" />
				</span>
				<h2>{{ off ? $t('The server is off') : restart ? $t('Restarting now') : $t('Now shutting down') }}</h2>
				<p class="atrio-update-versions">{{ elapsed }}</p>

				<ol class="atrio-update-steps atrio-power-steps">
					<li v-for="step in steps" :key="step.label" :class="step.state">
						<span class="atrio-update-step-icon">
							<b-icon v-if="step.state === 'is-done'" custom-size="mdi-18px" icon="check" pack="mdi" />
							<span v-else-if="step.state === 'is-active'" class="atrio-update-spinner" />
						</span>
						{{ $t(step.label) }}
					</li>
				</ol>

				<p :class="{ 'is-warning': slow && !off }" class="atrio-update-note">{{ note }}</p>
				<button v-if="slow || off" class="atrio-update-close" type="button" @click="off ? $emit('close') : reload()">
					{{ off ? $t('Close') : $t('Reload') }}
				</button>
			</div>
		</div>
	</Teleport>
</template>

<style lang="scss">
.atrio-power-mark {
	display: grid;
	place-items: center;
	width: 3.5rem;
	height: 3.5rem;
	border-radius: 50%;
	background: rgba(10, 165, 196, 0.16);
	color: var(--atrio-accent);

	.icon,
	.mdi::before {
		width: auto;
		height: auto;
		font-size: 1.75rem;
	}

	&.is-off {
		background: rgba(255, 255, 255, 0.08);
		color: var(--atrio-text-muted);
	}
}

.atrio-power-steps {
	margin-top: 1.5rem;
}

.atrio-update-note.is-warning {
	color: #fde68a;
}
</style>
